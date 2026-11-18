import CMData
import Foundation

public enum CoMotionArchiveFormat
{
    public static let formatVersion: UInt32 = 2
    public static let rigFormatVersion = RigMotionArchiveCodec.version
    public static let meshSchemaVersion: UInt32 = 1
    public static let modelCompatibilityVersion: UInt32 = 2
    public static let smplCompatibilityVersion: UInt32 = 1
    public static let maximumPeoplePerFrame = 8
    public static let maximumFrameCount = 10_000_000
    public static let maximumDimension = 16_384
    public static let maximumFrameRate: Float = 1_000
    public static let maximumArchiveByteCount = 16 * 1_024 * 1_024 * 1_024

    static let magic: UInt32 = 0x434D5343
    static let headerByteCount = 128
    static let frameRecordVersion: UInt32 = 1
    static let availableStatus: UInt32 = 0
    static let failedStatus: UInt32 = 1
    static let personRecordByteCount = (1 + CoMotionMeshParameters.totalFloatCount) * 4
}

public typealias CoMotionArchiveMetadata = CMData.CoMotionArchiveMetadata
public typealias CoMotionFrameFailureCode = CMData.CoMotionFrameFailureCode

extension CMData.CoMotionArchiveMetadata
{
    public var sourceSize: SIMD2<Float>
    {
        SIMD2(Float(encodedWidth), Float(encodedHeight))
    }
}

public struct CoMotionRigPerson: Sendable
{
    public let confidence: Float
    public let skinningTransforms: [Float]
    public let translation: SIMD3<Float>

    public init(confidence: Float, skinningTransforms: [Float], translation: SIMD3<Float>)
    {
        self.confidence = confidence
        self.skinningTransforms = skinningTransforms
        self.translation = translation
    }
}

public struct CoMotionFramePerson: Equatable, Sendable
{
    public let confidence: Float
    public let meshParameters: CoMotionMeshParameters

    public init(confidence: Float, meshParameters: CoMotionMeshParameters)
    {
        self.confidence = confidence
        self.meshParameters = meshParameters
    }

    public var rigPerson: CoMotionRigPerson
    {
        let translation = meshParameters.translation
        return CoMotionRigPerson(
            confidence: confidence,
            skinningTransforms: meshParameters.skinningTransforms,
            translation: SIMD3(translation[0], translation[1], translation[2])
        )
    }
}

public enum CoMotionFrameStatus: Equatable, Sendable
{
    case available([CoMotionFramePerson])
    case failed(CoMotionFrameFailureCode)
}

public struct CoMotionFrame: Equatable, Sendable
{
    public let videoFrameOrdinal: Int
    public let sourceFrameIndex: Int
    public let status: CoMotionFrameStatus

    public init(
        videoFrameOrdinal: Int,
        sourceFrameIndex: Int,
        status: CoMotionFrameStatus
    )
    {
        self.videoFrameOrdinal = videoFrameOrdinal
        self.sourceFrameIndex = sourceFrameIndex
        self.status = status
    }
}
