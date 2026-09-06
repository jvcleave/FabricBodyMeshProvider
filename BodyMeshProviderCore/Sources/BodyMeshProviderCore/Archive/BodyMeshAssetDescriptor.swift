import Foundation

public enum BodyMeshAssetDescriptorError: LocalizedError, Equatable, Sendable
{
    case unsupported(String)
    case payloadMismatch

    public var errorDescription: String?
    {
        switch self
        {
            case let .unsupported(description):
                return "The body mesh asset descriptor is unsupported: \(description)."
            case .payloadMismatch:
                return "The body mesh asset descriptor does not match frames.bin."
        }
    }
}

public struct BodyMeshAssetDescriptor: Codable, Equatable, Sendable
{
    public static let currentVersion = 1
    public static let fileName = "asset.json"
    public static let payloadFileName = "frames.bin"

    public let descriptorVersion: Int
    public let id: UUID
    public let kind: String
    public let name: String
    public let createdAt: Date
    public let width: Int
    public let height: Int
    public let frameRate: Float
    public let frameCount: Int
    public let failedFrameCount: Int
    public let payloadFileName: String
    public let payloadByteCount: Int
    public let thumbnailFileName: String?
    public let originDisplayName: String?
    public let originVideoSourceID: UUID
    public let originEncodedArtifactGeneration: UUID
    public let resizingModeIdentifier: UInt64
    public let frameRateConversionModeIdentifier: UInt64
    public let payloadFormatVersion: UInt32
    public let meshSchemaVersion: UInt32
    public let modelCompatibilityVersion: UInt32
    public let smplCompatibilityVersion: UInt32

    public static func loadIfPresent(directoryURL: URL) throws -> BodyMeshAssetDescriptor?
    {
        let descriptorURL = directoryURL.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: descriptorURL.path) else { return nil }
        let descriptor = try JSONDecoder().decode(
            BodyMeshAssetDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        try descriptor.validateSupportedValues()
        return descriptor
    }

    public func validate(archiveReader: CoMotionArchiveReader) throws
    {
        let metadata = archiveReader.metadata
        guard width == metadata.encodedWidth,
              height == metadata.encodedHeight,
              frameRate == metadata.encodedFrameRate,
              frameCount == archiveReader.frameCount,
              failedFrameCount == archiveReader.failedFrameCount,
              payloadByteCount == archiveReader.payloadByteCount,
              originVideoSourceID == metadata.videoSourceID,
              originEncodedArtifactGeneration == metadata.encodedArtifactGeneration,
              resizingModeIdentifier == metadata.resizingModeIdentifier,
              frameRateConversionModeIdentifier == metadata.frameRateConversionModeIdentifier,
              modelCompatibilityVersion == metadata.modelCompatibilityVersion,
              smplCompatibilityVersion == metadata.smplCompatibilityVersion
        else
        {
            throw BodyMeshAssetDescriptorError.payloadMismatch
        }
    }

    private func validateSupportedValues() throws
    {
        guard descriptorVersion == Self.currentVersion else
        {
            throw BodyMeshAssetDescriptorError.unsupported(
                "descriptor version \(descriptorVersion)"
            )
        }
        guard kind == "coMotionSMPL" else
        {
            throw BodyMeshAssetDescriptorError.unsupported("kind \(kind)")
        }
        guard name.isEmpty == false else
        {
            throw BodyMeshAssetDescriptorError.unsupported("empty name")
        }
        guard payloadFileName == Self.payloadFileName else
        {
            throw BodyMeshAssetDescriptorError.unsupported(
                "payload file \(payloadFileName)"
            )
        }
        guard payloadFormatVersion == CoMotionArchiveFormat.formatVersion,
              meshSchemaVersion == CoMotionArchiveFormat.meshSchemaVersion,
              modelCompatibilityVersion == CoMotionArchiveFormat.modelCompatibilityVersion,
              smplCompatibilityVersion == CoMotionArchiveFormat.smplCompatibilityVersion
        else
        {
            throw BodyMeshAssetDescriptorError.unsupported("compatibility versions")
        }
    }
}
