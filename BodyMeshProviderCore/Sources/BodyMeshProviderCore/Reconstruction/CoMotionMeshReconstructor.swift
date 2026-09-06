import Accelerate
import Foundation
import simd

public enum CoMotionMeshReconstructionError: LocalizedError, Equatable, Sendable
{
    case invalidConstantsByteCount(expected: Int, actual: Int)
    case invalidConstantsHeader
    case nonFiniteConstants
    case invalidTriangleIndex
    case invalidSkinningWeights
    case zeroHomogeneousWeight
    case nonFiniteVertex
    case invalidNormal

    public var errorDescription: String?
    {
        switch self
        {
            case let .invalidConstantsByteCount(expected, actual):
                return "The CoMotion mesh constants contain \(actual) bytes; expected \(expected)."
            case .invalidConstantsHeader:
                return "The CoMotion mesh constants have an incompatible header."
            case .nonFiniteConstants:
                return "The CoMotion mesh constants contain a non-finite value."
            case .invalidTriangleIndex:
                return "The CoMotion mesh constants contain an invalid triangle index."
            case .invalidSkinningWeights:
                return "The CoMotion mesh constants contain invalid skinning weights."
            case .zeroHomogeneousWeight:
                return "CoMotion mesh skinning produced a zero homogeneous weight."
            case .nonFiniteVertex:
                return "CoMotion mesh reconstruction produced a non-finite vertex."
            case .invalidNormal:
                return "CoMotion mesh reconstruction produced an invalid normal."
        }
    }
}

public struct CoMotionBodyMesh: Sendable
{
    public let vertices: [SIMD3<Float>]
    public let localVertices: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let triangleIndices: [UInt32]

    public init(
        vertices: [SIMD3<Float>],
        localVertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        triangleIndices: [UInt32]
    )
    {
        self.vertices = vertices
        self.localVertices = localVertices
        self.normals = normals
        self.triangleIndices = triangleIndices
    }
}

public struct CoMotionMeshReconstructionWorkspace: Sendable
{
    fileprivate var posedVertices: [Float]
    fileprivate var offsets: [Float]
    fileprivate var transforms: [Float]
    fileprivate var vertices: [SIMD3<Float>]
    fileprivate var localVertices: [SIMD3<Float>]
    fileprivate var normals: [SIMD3<Float>]

    public init()
    {
        posedVertices = []
        posedVertices.reserveCapacity(CoMotionMeshReconstructor.vertexCount * 3)
        offsets = [Float](
            repeating: 0,
            count: CoMotionMeshReconstructor.vertexCount * 3
        )
        transforms = [Float](
            repeating: 0,
            count: CoMotionMeshReconstructor.vertexCount * 16
        )
        vertices = []
        vertices.reserveCapacity(CoMotionMeshReconstructor.vertexCount)
        localVertices = []
        localVertices.reserveCapacity(CoMotionMeshReconstructor.vertexCount)
        normals = []
        normals.reserveCapacity(CoMotionMeshReconstructor.vertexCount)
    }

    fileprivate mutating func reset(
        vertexTemplate: [Float],
        includeLocalVertices: Bool
    )
    {
        posedVertices.removeAll(keepingCapacity: true)
        posedVertices.append(contentsOf: vertexTemplate)
        for offsetIndex in offsets.indices
        {
            offsets[offsetIndex] = 0
        }
        for transformIndex in transforms.indices
        {
            transforms[transformIndex] = 0
        }
        vertices.removeAll(keepingCapacity: true)
        localVertices.removeAll(keepingCapacity: true)
        if includeLocalVertices
        {
            localVertices.reserveCapacity(CoMotionMeshReconstructor.vertexCount)
        }
        normals.removeAll(keepingCapacity: true)
    }
}

public struct CoMotionMeshReconstructor: Sendable
{
    public static let vertexCount = 6_890
    public static let triangleCount = 13_776
    public static let expectedConstantsByteCount = 18_851_008

    private let triangleIndices: [UInt32]
    private let vertexTemplate: [Float]
    private let shapeDirections: [Float]
    private let poseDirections: [Float]
    private let skinningWeights: [Float]
    private let canonicalNormals: [SIMD3<Float>]

    public init(constantsData: Data) throws
    {
        guard constantsData.count == Self.expectedConstantsByteCount else
        {
            throw CoMotionMeshReconstructionError.invalidConstantsByteCount(
                expected: Self.expectedConstantsByteCount,
                actual: constantsData.count
            )
        }

        let floatCount = Self.vertexCount * (3 + 30 + 621 + 24)
        let words: [UInt32] = constantsData.withUnsafeBytes
        { bytes in
            var decodedWords: [UInt32] = []
            decodedWords.reserveCapacity(constantsData.count / 4)
            for wordIndex in 0 ..< constantsData.count / 4
            {
                decodedWords.append(
                    UInt32(
                        littleEndian: bytes.loadUnaligned(
                            fromByteOffset: wordIndex * 4,
                            as: UInt32.self
                        )
                    )
                )
            }
            return decodedWords
        }
        let expectedHeader: [UInt32] = [
            0x434D5348,
            1,
            UInt32(Self.vertexCount),
            UInt32(Self.triangleCount),
        ]
        guard Array(words.prefix(4)) == expectedHeader else
        {
            throw CoMotionMeshReconstructionError.invalidConstantsHeader
        }

        let floats = words[4 ..< 4 + floatCount].map(Float.init(bitPattern:))
        guard floats.allSatisfy(\.isFinite) else
        {
            throw CoMotionMeshReconstructionError.nonFiniteConstants
        }
        vertexTemplate = Array(floats[0 ..< Self.vertexCount * 3])
        shapeDirections = Array(floats[Self.vertexCount * 3 ..< Self.vertexCount * 33])
        poseDirections = Array(floats[Self.vertexCount * 33 ..< Self.vertexCount * 654])
        skinningWeights = Array(floats[Self.vertexCount * 654 ..< floatCount])
        triangleIndices = Array(words[(4 + floatCount)...])

        guard triangleIndices.count == Self.triangleCount * 3,
              triangleIndices.allSatisfy({ $0 < UInt32(Self.vertexCount) })
        else
        {
            throw CoMotionMeshReconstructionError.invalidTriangleIndex
        }
        for vertexIndex in 0 ..< Self.vertexCount
        {
            let weights = skinningWeights[
                vertexIndex * 24 ..< (vertexIndex + 1) * 24
            ]
            guard weights.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                  abs(weights.reduce(0, +) - 1) < 0.0001
            else
            {
                throw CoMotionMeshReconstructionError.invalidSkinningWeights
            }
        }

        var templatePositions: [SIMD3<Float>] = []
        templatePositions.reserveCapacity(Self.vertexCount)
        for vertexIndex in 0 ..< Self.vertexCount
        {
            let positionIndex = vertexIndex * 3
            templatePositions.append(
                SIMD3(
                    vertexTemplate[positionIndex],
                    vertexTemplate[positionIndex + 1],
                    vertexTemplate[positionIndex + 2]
                )
            )
        }
        var accumulatedNormals = [SIMD3<Float>](
            repeating: .zero,
            count: Self.vertexCount
        )
        for triangleIndex in 0 ..< Self.triangleCount
        {
            let indexOffset = triangleIndex * 3
            let firstIndex = Int(triangleIndices[indexOffset])
            let secondIndex = Int(triangleIndices[indexOffset + 1])
            let thirdIndex = Int(triangleIndices[indexOffset + 2])
            let firstPosition = templatePositions[firstIndex]
            let secondPosition = templatePositions[secondIndex]
            let thirdPosition = templatePositions[thirdIndex]
            let faceNormal = simd_cross(
                secondPosition - firstPosition,
                thirdPosition - firstPosition
            )
            accumulatedNormals[firstIndex] += faceNormal
            accumulatedNormals[secondIndex] += faceNormal
            accumulatedNormals[thirdIndex] += faceNormal
        }
        canonicalNormals = try accumulatedNormals.map
        { normal in
            let length = simd_length(normal)
            guard length.isFinite, length > 0.000_001 else
            {
                throw CoMotionMeshReconstructionError.invalidNormal
            }
            return normal / length
        }
    }

    public func reconstructMesh(
        parameters: CoMotionMeshParameters
    ) throws -> CoMotionBodyMesh
    {
        var workspace = CoMotionMeshReconstructionWorkspace()
        return try reconstructMesh(
            parameters: parameters,
            workspace: &workspace,
            includeLocalVertices: true
        )
    }

    public func reconstructMesh(
        parameters: CoMotionMeshParameters,
        workspace: inout CoMotionMeshReconstructionWorkspace,
        includeLocalVertices: Bool
    ) throws -> CoMotionBodyMesh
    {
        workspace.reset(
            vertexTemplate: vertexTemplate,
            includeLocalVertices: includeLocalVertices
        )
        vDSP_mmul(
            shapeDirections,
            1,
            parameters.betas,
            1,
            &workspace.offsets,
            1,
            vDSP_Length(Self.vertexCount * 3),
            1,
            vDSP_Length(CoMotionMeshParameters.betaCount)
        )
        vDSP_vadd(
            workspace.posedVertices,
            1,
            workspace.offsets,
            1,
            &workspace.posedVertices,
            1,
            vDSP_Length(Self.vertexCount * 3)
        )
        vDSP_mmul(
            poseDirections,
            1,
            parameters.poseFeature,
            1,
            &workspace.offsets,
            1,
            vDSP_Length(Self.vertexCount * 3),
            1,
            vDSP_Length(CoMotionMeshParameters.poseFeatureCount)
        )
        vDSP_vadd(
            workspace.posedVertices,
            1,
            workspace.offsets,
            1,
            &workspace.posedVertices,
            1,
            vDSP_Length(Self.vertexCount * 3)
        )
        vDSP_mmul(
            skinningWeights,
            1,
            parameters.skinningTransforms,
            1,
            &workspace.transforms,
            1,
            vDSP_Length(Self.vertexCount),
            16,
            24
        )
        let translation = SIMD3(
            parameters.translation[0],
            parameters.translation[1],
            parameters.translation[2]
        )
        for vertexIndex in 0 ..< Self.vertexCount
        {
            let positionIndex = vertexIndex * 3
            let transformIndex = vertexIndex * 16
            let position = SIMD4(
                workspace.posedVertices[positionIndex],
                workspace.posedVertices[positionIndex + 1],
                workspace.posedVertices[positionIndex + 2],
                1
            )
            var transformedPosition = SIMD4<Float>(repeating: 0)
            for rowIndex in 0 ..< 4
            {
                let rowStart = transformIndex + rowIndex * 4
                let row = SIMD4(
                    workspace.transforms[rowStart],
                    workspace.transforms[rowStart + 1],
                    workspace.transforms[rowStart + 2],
                    workspace.transforms[rowStart + 3]
                )
                transformedPosition[rowIndex] = simd_dot(row, position)
            }
            guard abs(transformedPosition.w) > 0.000_001 else
            {
                throw CoMotionMeshReconstructionError.zeroHomogeneousWeight
            }
            let localVertex = SIMD3(
                transformedPosition.x,
                transformedPosition.y,
                transformedPosition.z
            ) / transformedPosition.w
            let vertex = localVertex + translation
            guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else
            {
                throw CoMotionMeshReconstructionError.nonFiniteVertex
            }

            let canonicalNormal = canonicalNormals[vertexIndex]
            let transformedNormal = SIMD3(
                workspace.transforms[transformIndex] * canonicalNormal.x
                    + workspace.transforms[transformIndex + 1] * canonicalNormal.y
                    + workspace.transforms[transformIndex + 2] * canonicalNormal.z,
                workspace.transforms[transformIndex + 4] * canonicalNormal.x
                    + workspace.transforms[transformIndex + 5] * canonicalNormal.y
                    + workspace.transforms[transformIndex + 6] * canonicalNormal.z,
                workspace.transforms[transformIndex + 8] * canonicalNormal.x
                    + workspace.transforms[transformIndex + 9] * canonicalNormal.y
                    + workspace.transforms[transformIndex + 10] * canonicalNormal.z
            )
            let normalLength = simd_length(transformedNormal)
            guard normalLength.isFinite, normalLength > 0.000_001 else
            {
                throw CoMotionMeshReconstructionError.invalidNormal
            }

            if includeLocalVertices
            {
                workspace.localVertices.append(localVertex)
            }
            workspace.vertices.append(vertex)
            workspace.normals.append(transformedNormal / normalLength)
        }
        return CoMotionBodyMesh(
            vertices: workspace.vertices,
            localVertices: workspace.localVertices,
            normals: workspace.normals,
            triangleIndices: triangleIndices
        )
    }
}
