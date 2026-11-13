import BodyMeshProviderCore
import Darwin
import Foundation
import Satin
import simd

enum BodyMeshGeometryError: LocalizedError
{
    case inconsistentMeshData
    case allocationFailed(byteCount: Int)

    var errorDescription: String?
    {
        switch self
        {
            case .inconsistentMeshData:
                return "Body mesh reconstruction produced inconsistent vertex or topology data."
            case let .allocationFailed(byteCount):
                return "Body mesh geometry could not allocate \(byteCount) bytes."
        }
    }
}

final class BodyMeshGeometry: SatinGeometry
{
    private var reusableVertices: [SatinVertex] = []
    private var cachedTrianglesByBodyCount: [Int: [TriangleIndices]] = [:]
    private var preparedGeometryData = createGeometryData()
    private var skinningMesh: CoMotionSkinningMesh?
    private var skinnedBodyCount = 0
    private var skinningElements: ElementBuffer?
    private var skinningMatrices: [simd_float4x4] = []
    private var skinnedBounds = createBounds()

    deinit
    {
        freeGeometryData(&preparedGeometryData)
    }

    func replaceMeshes<Source: Sequence>(
        from sources: Source,
        expectedBodyCount: Int,
        reconstructMesh: (Source.Element) throws -> CoMotionBodyMesh
    ) throws
    {
        disableSkinning()
        reusableVertices.removeAll(keepingCapacity: true)
        reusableVertices.reserveCapacity(
            expectedBodyCount * CoMotionMeshReconstructor.vertexCount
        )

        var baseTriangleIndices: [UInt32]?
        var reconstructedBodyCount = 0
        for source in sources
        {
            let mesh = try reconstructMesh(source)
            guard mesh.vertices.count == mesh.normals.count,
                  mesh.vertices.count == CoMotionMeshReconstructor.vertexCount,
                  mesh.triangleIndices.count == CoMotionMeshReconstructor.triangleCount * 3,
                  baseTriangleIndices == nil || baseTriangleIndices == mesh.triangleIndices
            else
            {
                throw BodyMeshGeometryError.inconsistentMeshData
            }

            baseTriangleIndices = mesh.triangleIndices
            for (position, normal) in zip(mesh.vertices, mesh.normals)
            {
                reusableVertices.append(
                    SatinVertex(
                        position: Self.fabricCoordinates(position),
                        normal: Self.fabricCoordinates(normal),
                        uv: .zero
                    )
                )
            }
            reconstructedBodyCount += 1
        }

        guard reconstructedBodyCount == expectedBodyCount else
        {
            throw BodyMeshGeometryError.inconsistentMeshData
        }
        guard reconstructedBodyCount > 0, let baseTriangleIndices else
        {
            clearMeshes()
            return
        }

        let triangles = cachedTriangles(
            bodyCount: reconstructedBodyCount,
            baseTriangleIndices: baseTriangleIndices
        )
        let newGeometryData = try makeGeometryData(triangles: triangles)
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = newGeometryData
        _updateData = true
    }

    /// Archive transforms are row-major affine matrices. Projective data still
    /// needs the CPU path's per-vertex homogeneous divide.
    static func canSkinOnGPU(_ parameters: CoMotionMeshParameters) -> Bool
    {
        let matrices = parameters.skinningTransforms
        for row in stride(from: 12, to: matrices.count, by: 16)
        {
            guard matrices[row] == 0, matrices[row + 1] == 0,
                  matrices[row + 2] == 0, matrices[row + 3] == 1
            else { return false }
        }
        return true
    }

    func replaceSkinnedMeshes<People: Collection>(
        from people: People,
        reconstructor: CoMotionMeshReconstructor,
        workspace: inout CoMotionBlendShapeWorkspace
    ) throws where People.Element == CoMotionMeshParameters
    {
        guard people.isEmpty == false else
        {
            clearMeshes()
            return
        }

        let skinningMesh = try self.skinningMesh ?? reconstructor.makeSkinningMesh()
        self.skinningMesh = skinningMesh
        let bodyCount = people.count
        let vertexCount = CoMotionMeshReconstructor.vertexCount
        let jointCount = CoMotionMeshParameters.jointCount

        reusableVertices.removeAll(keepingCapacity: true)
        reusableVertices.reserveCapacity(bodyCount * vertexCount)
        skinningMatrices.removeAll(keepingCapacity: true)
        skinningMatrices.reserveCapacity(bodyCount * jointCount)
        var frameBounds = createBounds()
        for parameters in people
        {
            let positions = reconstructor.blendShapePositions(parameters: parameters, workspace: &workspace)
            var bodyBounds = createBounds()
            for vertexIndex in 0 ..< vertexCount
            {
                let offset = vertexIndex * 3
                let position = Self.fabricCoordinates(SIMD3(positions[offset], positions[offset + 1], positions[offset + 2]))
                guard position.x.isFinite, position.y.isFinite, position.z.isFinite else
                {
                    throw CoMotionMeshReconstructionError.nonFiniteVertex
                }
                bodyBounds.min = simd_min(bodyBounds.min, position)
                bodyBounds.max = simd_max(bodyBounds.max, position)
                reusableVertices.append(
                    SatinVertex(position: position, normal: Self.fabricCoordinates(skinningMesh.canonicalNormals[vertexIndex]), uv: .zero)
                )
            }
            let firstJoint = skinningMatrices.count
            try appendSkinningMatrices(parameters)
            // Each skinned position is a weighted average of joint-transformed
            // positions, so the union of the transformed boxes encloses the body.
            for matrix in skinningMatrices[firstJoint...]
            {
                let jointBounds = transformBounds(bodyBounds, matrix)
                guard jointBounds.min.x.isFinite, jointBounds.min.y.isFinite, jointBounds.min.z.isFinite,
                      jointBounds.max.x.isFinite, jointBounds.max.y.isFinite, jointBounds.max.z.isFinite
                else
                {
                    throw CoMotionMeshReconstructionError.nonFiniteVertex
                }
                frameBounds = mergeBounds(frameBounds, jointBounds)
            }
        }

        let topologyChanged = skinnedBodyCount != bodyCount
        if topologyChanged
        {
            let triangles = cachedTriangles(bodyCount: bodyCount, baseTriangleIndices: skinningMesh.triangleIndices)
            skinningElements = try makeSkinningElements(triangles)
            skinnedBodyCount = bodyCount
        }

        let vertexData = try makeGeometryData()
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = vertexData
        skinnedBounds = frameBounds
        _updateData = true

        if topologyChanged
        {
            var jointIndices: [SIMD4<UInt16>] = []
            var jointWeights: [SIMD4<Float>] = []
            jointIndices.reserveCapacity(bodyCount * vertexCount)
            jointWeights.reserveCapacity(bodyCount * vertexCount)
            for bodyIndex in 0 ..< bodyCount
            {
                let jointOffset = SIMD4<UInt16>(repeating: UInt16(bodyIndex * jointCount))
                for indices in skinningMesh.jointIndices
                {
                    jointIndices.append(indices &+ jointOffset)
                }
                jointWeights.append(contentsOf: skinningMesh.jointWeights)
            }
            addAttribute(UShort4BufferAttribute(defaultValue: .zero, data: jointIndices), for: .JointIndices)
            addAttribute(Float4BufferAttribute(defaultValue: .zero, data: jointWeights), for: .JointWeights)
            jointPalette = JointPalette(jointCount: bodyCount * jointCount)
        }
        // The archive has no tracked person IDs or previous blend-shape
        // positions, so a new archive pose has no reliable velocity history.
        jointPalette?.reset(matrices: skinningMatrices)
    }

    func clearMeshes()
    {
        disableSkinning()
        reusableVertices.removeAll(keepingCapacity: true)
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = createGeometryData()
        _updateData = true
    }

    func releaseResources()
    {
        disableSkinning()
        skinningMesh = nil
        skinningMatrices.removeAll(keepingCapacity: false)
        reusableVertices.removeAll(keepingCapacity: false)
        cachedTrianglesByBodyCount.removeAll(keepingCapacity: false)
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = createGeometryData()
        _updateData = true
        update()
    }

    override func generateGeometryData() -> GeometryData
    {
        let geometryData = preparedGeometryData
        preparedGeometryData = createGeometryData()
        return geometryData
    }

    override func updateData()
    {
        super.updateData()
        if let skinningElements
        {
            setElements(skinningElements)
        }
    }

    override func update()
    {
        super.update()
        if skinningElements == nil, hasAttribute(.JointIndices)
        {
            removeAttribute(.JointIndices)
            removeAttribute(.JointWeights)
        }
    }

    override func computeBounds() -> Bounds
    {
        skinningElements == nil ? super.computeBounds() : skinnedBounds
    }

    private static func fabricCoordinates(_ vector: SIMD3<Float>) -> SIMD3<Float>
    {
        // CoMotion has +Y down and +Z forward. Fabric has +Y up and -Z forward.
        SIMD3(vector.x, -vector.y, -vector.z)
    }

    private func appendSkinningMatrices(_ parameters: CoMotionMeshParameters) throws
    {
        let matrices = parameters.skinningTransforms
        let translation = parameters.translation
        for offset in stride(from: 0, to: matrices.count, by: 16)
        {
            let translated = SIMD3(
                matrices[offset + 3] + translation[0],
                matrices[offset + 7] + translation[1],
                matrices[offset + 11] + translation[2]
            )
            guard translated.x.isFinite, translated.y.isFinite, translated.z.isFinite else
            {
                throw CoMotionMeshReconstructionError.nonFiniteSkinningTransform
            }
            // Change basis on both sides of the joint transform. Add the
            // archive translation in Fabric coordinates after skinning.
            skinningMatrices.append(simd_float4x4(columns: (
                SIMD4(matrices[offset], -matrices[offset + 4], -matrices[offset + 8], 0),
                SIMD4(-matrices[offset + 1], matrices[offset + 5], matrices[offset + 9], 0),
                SIMD4(-matrices[offset + 2], matrices[offset + 6], matrices[offset + 10], 0),
                SIMD4(Self.fabricCoordinates(translated), 1)
            )))
        }
    }

    private func disableSkinning()
    {
        guard skinningElements != nil else { return }
        skinnedBodyCount = 0
        jointPalette = nil
        // Satin clears a vertex-buffer binding when its attribute has no data.
        // Keep the empty attributes through the next update so it can clear them.
        (getAttribute(.JointIndices) as? UShort4BufferAttribute)?.data = []
        (getAttribute(.JointWeights) as? Float4BufferAttribute)?.data = []
        setElements(nil)
        skinningElements = nil
    }

    private func makeSkinningElements(_ triangles: [TriangleIndices]) throws -> ElementBuffer
    {
        let byteCount = triangles.count * MemoryLayout<TriangleIndices>.stride
        guard let data = NSMutableData(length: byteCount) else
        {
            throw BodyMeshGeometryError.allocationFailed(byteCount: byteCount)
        }
        triangles.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress
            {
                data.mutableBytes.copyMemory(from: source, byteCount: byteCount)
            }
        }
        return ElementBuffer(type: .uint32, data: data.mutableBytes, count: triangles.count * 3, source: data)
    }

    private func cachedTriangles(
        bodyCount: Int,
        baseTriangleIndices: [UInt32]
    ) -> [TriangleIndices]
    {
        if let cachedTriangles = cachedTrianglesByBodyCount[bodyCount]
        {
            return cachedTriangles
        }

        var triangles: [TriangleIndices] = []
        triangles.reserveCapacity(bodyCount * CoMotionMeshReconstructor.triangleCount)
        for bodyIndex in 0 ..< bodyCount
        {
            let vertexOffset = UInt32(bodyIndex * CoMotionMeshReconstructor.vertexCount)
            for triangleStart in stride(
                from: baseTriangleIndices.startIndex,
                to: baseTriangleIndices.endIndex,
                by: 3
            )
            {
                triangles.append(
                    TriangleIndices(
                        i0: baseTriangleIndices[triangleStart] + vertexOffset,
                        i1: baseTriangleIndices[triangleStart + 1] + vertexOffset,
                        i2: baseTriangleIndices[triangleStart + 2] + vertexOffset
                    )
                )
            }
        }
        cachedTrianglesByBodyCount[bodyCount] = triangles
        return triangles
    }

    private func makeGeometryData(triangles: [TriangleIndices] = []) throws -> GeometryData
    {
        var geometryData = createGeometryData()
        do
        {
            geometryData.vertexData = try Self.copyToGeometryStorage(reusableVertices)
            geometryData.vertexCount = Int32(reusableVertices.count)
            geometryData.indexData = try Self.copyToGeometryStorage(triangles)
            geometryData.indexCount = Int32(triangles.count)
        }
        catch
        {
            freeGeometryData(&geometryData)
            throw error
        }
        return geometryData
    }

    private static func copyToGeometryStorage<Element>(_ values: [Element]) throws -> UnsafeMutablePointer<Element>?
    {
        try values.withUnsafeBufferPointer
        { buffer in
            guard let address = buffer.baseAddress, buffer.isEmpty == false else { return nil }
            let byteCount = buffer.count * MemoryLayout<Element>.stride
            guard let allocation = malloc(byteCount) else
            {
                throw BodyMeshGeometryError.allocationFailed(byteCount: byteCount)
            }
            let pointer = allocation.bindMemory(to: Element.self, capacity: buffer.count)
            pointer.initialize(from: address, count: buffer.count)
            return pointer
        }
    }
}
