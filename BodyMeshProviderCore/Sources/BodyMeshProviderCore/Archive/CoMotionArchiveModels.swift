import Foundation

public enum CoMotionArchiveFormat
{
    public static let formatVersion: UInt32 = 2
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

public struct CoMotionArchiveMetadata: Equatable, Sendable
{
    public let videoSourceID: UUID
    public let encodedArtifactGeneration: UUID
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let encodedFrameRate: Float
    public let resizingModeIdentifier: UInt64
    public let frameRateConversionModeIdentifier: UInt64
    public let modelCompatibilityVersion: UInt32
    public let smplCompatibilityVersion: UInt32

    public var sourceSize: SIMD2<Float>
    {
        SIMD2(Float(encodedWidth), Float(encodedHeight))
    }

    public init(
        videoSourceID: UUID,
        encodedArtifactGeneration: UUID,
        encodedWidth: Int,
        encodedHeight: Int,
        encodedFrameRate: Float,
        resizingModeIdentifier: UInt64,
        frameRateConversionModeIdentifier: UInt64,
        modelCompatibilityVersion: UInt32,
        smplCompatibilityVersion: UInt32
    )
    {
        self.videoSourceID = videoSourceID
        self.encodedArtifactGeneration = encodedArtifactGeneration
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.encodedFrameRate = encodedFrameRate
        self.resizingModeIdentifier = resizingModeIdentifier
        self.frameRateConversionModeIdentifier = frameRateConversionModeIdentifier
        self.modelCompatibilityVersion = modelCompatibilityVersion
        self.smplCompatibilityVersion = smplCompatibilityVersion
    }
}

public enum CoMotionFrameFailureCode: UInt32, Equatable, Sendable
{
    case videoDecode = 1
    case prediction = 2
    case invalidPredictionOutput = 3
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
