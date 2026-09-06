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
    private var currentTriangles: [TriangleIndices] = []
    private var cachedTrianglesByBodyCount: [Int: [TriangleIndices]] = [:]
    private var preparedGeometryData = createGeometryData()

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
                // CoMotion uses camera coordinates: +x right, +y down, +z forward.
                // Fabric's default camera uses +x right, +y up, -z forward.
                reusableVertices.append(
                    SatinVertex(
                        position: SIMD3(
                            position.x,
                            -position.y,
                            -position.z
                        ),
                        normal: SIMD3(
                            normal.x,
                            -normal.y,
                            -normal.z
                        ),
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

        currentTriangles = cachedTriangles(
            bodyCount: reconstructedBodyCount,
            baseTriangleIndices: baseTriangleIndices
        )
        let newGeometryData = try makePreparedGeometryData()
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = newGeometryData
        _updateData = true
    }

    func clearMeshes()
    {
        reusableVertices.removeAll(keepingCapacity: true)
        currentTriangles = []
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = createGeometryData()
        _updateData = true
    }

    func releaseResources()
    {
        reusableVertices.removeAll(keepingCapacity: false)
        currentTriangles.removeAll(keepingCapacity: false)
        cachedTrianglesByBodyCount.removeAll(keepingCapacity: false)
        freeGeometryData(&preparedGeometryData)
        preparedGeometryData = createGeometryData()
        _updateData = true
        updateGeometryData()
    }

    override func generateGeometryData() -> GeometryData
    {
        let geometryData = preparedGeometryData
        preparedGeometryData = createGeometryData()
        return geometryData
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

    private func makePreparedGeometryData() throws -> GeometryData
    {
        let vertexByteCount = reusableVertices.count * MemoryLayout<SatinVertex>.stride
        guard let vertexAllocation = malloc(vertexByteCount) else
        {
            throw BodyMeshGeometryError.allocationFailed(byteCount: vertexByteCount)
        }
        let vertexPointer = vertexAllocation.assumingMemoryBound(to: SatinVertex.self)
        reusableVertices.withUnsafeBufferPointer
        { sourceBuffer in
            if let sourceAddress = sourceBuffer.baseAddress
            {
                vertexPointer.initialize(
                    from: sourceAddress,
                    count: sourceBuffer.count
                )
            }
        }

        let triangleByteCount = currentTriangles.count * MemoryLayout<TriangleIndices>.stride
        guard let triangleAllocation = malloc(triangleByteCount) else
        {
            free(vertexAllocation)
            throw BodyMeshGeometryError.allocationFailed(byteCount: triangleByteCount)
        }
        let trianglePointer = triangleAllocation.assumingMemoryBound(to: TriangleIndices.self)
        currentTriangles.withUnsafeBufferPointer
        { sourceBuffer in
            if let sourceAddress = sourceBuffer.baseAddress
            {
                trianglePointer.initialize(
                    from: sourceAddress,
                    count: sourceBuffer.count
                )
            }
        }

        return GeometryData(
            vertexCount: Int32(reusableVertices.count),
            vertexData: vertexPointer,
            indexCount: Int32(currentTriangles.count),
            indexData: trianglePointer
        )
    }
}
