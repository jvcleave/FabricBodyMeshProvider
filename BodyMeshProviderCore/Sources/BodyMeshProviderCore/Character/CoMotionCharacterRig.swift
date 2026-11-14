import Foundation
import simd

public enum CoMotionCharacterRigError: LocalizedError, Sendable
{
    case invalidRig
    case invalidJointTransform(Int)
    case invalidPose
    case nonRigidPoseJoint(Int)

    public var errorDescription: String?
    {
        switch self
        {
            case .invalidRig:
                return "The character skeleton has an invalid hierarchy or CoMotion joint map."
            case let .invalidJointTransform(jointIndex):
                return "Character joint \(jointIndex) has an invalid bind or reference transform."
            case .invalidPose:
                return "The archive pose has invalid transforms."
            case let .nonRigidPoseJoint(jointIndex):
                return "Archive joint \(jointIndex) has a non-rigid transform."
        }
    }
}

/// Creator reference and bind transforms use right-handed Y-up meters.
/// The retargeting follows MessScene's prepared-character calibration in that basis.
public struct CoMotionCharacterRig: Sendable
{
    public struct Joint: Sendable
    {
        public let parent: Int?
        public let source: Int
        public let localReference: simd_float4x4
        public let inverseBind: simd_float4x4

        public init(parent: Int?, source: Int, localReference: simd_float4x4, inverseBind: simd_float4x4)
        {
            self.parent = parent
            self.source = source
            self.localReference = localReference
            self.inverseBind = inverseBind
        }
    }

    private struct ReferenceJoint: Sendable
    {
        let parent: Int?
        let source: Int
        let localReference: simd_float4x4
        let worldReference: simd_float4x4
        let inverseBind: simd_float4x4
    }

    private static let cameraToModel = simd_float3x3(diagonal: SIMD3<Float>(1, -1, -1))
    private static let sourceReferenceRoot = SIMD3<Float>(0, -0.20, 0)
    private let joints: [ReferenceJoint]
    private let pelvisIndex: Int
    public let referenceMatrices: [simd_float4x4]

    public init(joints: [Joint]) throws
    {
        guard (1 ... 128).contains(joints.count),
              joints.filter({ $0.source == 0 }).count == 1,
              let pelvisIndex = joints.firstIndex(where: { $0.source == 0 })
        else { throw CoMotionCharacterRigError.invalidRig }

        var references: [ReferenceJoint] = []
        var referenceMatrices: [simd_float4x4] = []
        references.reserveCapacity(joints.count)
        referenceMatrices.reserveCapacity(joints.count)
        for (jointIndex, joint) in joints.enumerated()
        {
            guard (-1 ..< CoMotionMeshParameters.jointCount).contains(joint.source),
                  joint.parent.map({ references.indices.contains($0) }) ?? true
            else { throw CoMotionCharacterRigError.invalidRig }
            let worldReference = joint.parent.map { references[$0].worldReference * joint.localReference } ?? joint.localReference
            guard Self.isRigid(worldReference, tolerance: 0.001), Self.isRigid(joint.inverseBind, tolerance: 0.001)
            else { throw CoMotionCharacterRigError.invalidJointTransform(jointIndex) }

            references.append(ReferenceJoint(
                parent: joint.parent,
                source: joint.source,
                localReference: joint.localReference,
                worldReference: worldReference,
                inverseBind: joint.inverseBind
            ))
            referenceMatrices.append(worldReference * joint.inverseBind)
        }
        self.joints = references
        self.pelvisIndex = pelvisIndex
        self.referenceMatrices = referenceMatrices
    }

    /// The archive provides 24 row-major skinning transforms in camera coordinates.
    /// Translation stored separately in the archive is applied by the caller.
    public func skinningMatrices(_ sourceTransforms: [Float]) throws -> [simd_float4x4]
    {
        guard sourceTransforms.count == CoMotionMeshParameters.skinningTransformCount,
              sourceTransforms.allSatisfy(\.isFinite)
        else { throw CoMotionCharacterRigError.invalidPose }

        var sourceMatrices: [simd_float4x4] = []
        sourceMatrices.reserveCapacity(CoMotionMeshParameters.jointCount)
        for start in stride(from: 0, to: sourceTransforms.count, by: 16)
        {
            let matrix = simd_float4x4(rows: [
                SIMD4(sourceTransforms[start], sourceTransforms[start + 1], sourceTransforms[start + 2], sourceTransforms[start + 3]),
                SIMD4(sourceTransforms[start + 4], sourceTransforms[start + 5], sourceTransforms[start + 6], sourceTransforms[start + 7]),
                SIMD4(sourceTransforms[start + 8], sourceTransforms[start + 9], sourceTransforms[start + 10], sourceTransforms[start + 11]),
                SIMD4(sourceTransforms[start + 12], sourceTransforms[start + 13], sourceTransforms[start + 14], sourceTransforms[start + 15])
            ])
            guard Self.isRigid(matrix, tolerance: 0.01)
            else { throw CoMotionCharacterRigError.nonRigidPoseJoint(sourceMatrices.count) }
            sourceMatrices.append(matrix)
        }

        var posed: [simd_float4x4] = []
        posed.reserveCapacity(joints.count)
        for joint in joints
        {
            var matrix = joint.parent.map { posed[$0] * joint.localReference } ?? joint.worldReference
            if joint.source >= 0
            {
                let rotation = Self.cameraToModel * Self.rotation(sourceMatrices[joint.source]) * Self.rotation(joint.worldReference)
                matrix.columns.0 = SIMD4(rotation.columns.0, 0)
                matrix.columns.1 = SIMD4(rotation.columns.1, 0)
                matrix.columns.2 = SIMD4(rotation.columns.2, 0)
            }
            posed.append(matrix)
        }

        // Keep the authored joint offsets. Register the Creator pelvis to the
        // calibrated CoMotion root before the caller adds the body translation.
        let cameraRoot = sourceMatrices[0] * SIMD4(Self.sourceReferenceRoot, 1)
        let modelRoot = Self.cameraToModel * SIMD3(cameraRoot.x, cameraRoot.y, cameraRoot.z)
        let pelvis = posed[pelvisIndex].columns.3
        let offset = SIMD4(modelRoot - SIMD3(pelvis.x, pelvis.y, pelvis.z), 0)
        var palette: [simd_float4x4] = []
        palette.reserveCapacity(joints.count)
        for jointIndex in joints.indices
        {
            posed[jointIndex].columns.3 += offset
            let matrix = posed[jointIndex] * joints[jointIndex].inverseBind
            guard (0 ..< 4).allSatisfy({ all(abs(matrix[$0]) .< SIMD4<Float>(repeating: .infinity)) })
            else { throw CoMotionCharacterRigError.invalidPose }
            palette.append(matrix)
        }
        return palette
    }

    private static func rotation(_ matrix: simd_float4x4) -> simd_float3x3
    {
        simd_float3x3(
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        )
    }

    private static func isRigid(_ matrix: simd_float4x4, tolerance: Float) -> Bool
    {
        let basis = rotation(matrix)
        let gram = basis.transpose * basis
        let affineRow = matrix.transpose.columns.3
        guard all(abs(affineRow - SIMD4(0, 0, 0, 1)) .< SIMD4(repeating: 0.001)),
              (0 ..< 4).allSatisfy({ all(abs(matrix[$0]) .< SIMD4<Float>(repeating: .infinity)) }),
              abs(simd_determinant(basis) - 1) < tolerance
        else { return false }
        for column in 0 ..< 3
        {
            guard all(abs(gram[column] - matrix_identity_float3x3[column]) .< SIMD3(repeating: tolerance))
            else { return false }
        }
        return true
    }
}
