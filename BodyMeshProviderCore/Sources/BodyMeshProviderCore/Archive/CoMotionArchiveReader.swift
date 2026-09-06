import Foundation

public enum CoMotionArchiveReaderError: LocalizedError, Equatable, Sendable
{
    case missingArchive(String)
    case invalidHeader(String)
    case invalidMetadata(String)
    case invalidFrame(String)
    case invalidPerson(String)
    case frameOutOfRange(Int)
    case truncated
    case exceedsSizeLimit

    public var errorDescription: String?
    {
        switch self
        {
            case let .missingArchive(fileName):
                return "The selected folder does not contain \(fileName)."
            case let .invalidHeader(description):
                return "Invalid CoMotion archive header: \(description)."
            case let .invalidMetadata(description):
                return "Invalid CoMotion archive metadata: \(description)."
            case let .invalidFrame(description):
                return "Invalid CoMotion archive frame: \(description)."
            case let .invalidPerson(description):
                return "Invalid CoMotion archive person: \(description)."
            case let .frameOutOfRange(frameIndex):
                return "CoMotion frame \(frameIndex) is outside the archive."
            case .truncated:
                return "The CoMotion archive is truncated."
            case .exceedsSizeLimit:
                return "The CoMotion archive exceeds its size limit."
        }
    }
}

public struct CoMotionArchiveReader: Sendable
{
    public static let archiveFileName = "frames.bin"

    public let metadata: CoMotionArchiveMetadata
    public let frameCount: Int
    public let failedFrameCount: Int
    public let payloadByteCount: Int

    private let data: Data
    private let frameOffsets: [Int]

    public var duration: TimeInterval
    {
        TimeInterval(frameCount) / TimeInterval(metadata.encodedFrameRate)
    }

    public init(directoryURL: URL) throws
    {
        let archiveURL = directoryURL.appending(path: Self.archiveFileName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: archiveURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue == false
        else
        {
            throw CoMotionArchiveReaderError.missingArchive(Self.archiveFileName)
        }
        try self.init(data: Data(contentsOf: archiveURL, options: .mappedIfSafe))
    }

    public init(data: Data) throws
    {
        guard data.count <= CoMotionArchiveFormat.maximumArchiveByteCount else
        {
            throw CoMotionArchiveReaderError.exceedsSizeLimit
        }

        var reader = BinaryReader(data: data)
        guard try reader.readUInt32() == CoMotionArchiveFormat.magic else
        {
            throw CoMotionArchiveReaderError.invalidHeader("magic changed")
        }
        guard try reader.readUInt32() == CoMotionArchiveFormat.formatVersion else
        {
            throw CoMotionArchiveReaderError.invalidHeader("format version changed")
        }
        guard try reader.readUInt32() == UInt32(CoMotionArchiveFormat.headerByteCount) else
        {
            throw CoMotionArchiveReaderError.invalidHeader("header size changed")
        }
        guard try reader.readUInt32() == CoMotionArchiveFormat.frameRecordVersion else
        {
            throw CoMotionArchiveReaderError.invalidHeader("frame record version changed")
        }

        let videoSourceID = try reader.readUUID()
        let encodedArtifactGeneration = try reader.readUUID()
        let encodedWidth = Int(try reader.readUInt32())
        let encodedHeight = Int(try reader.readUInt32())
        let encodedFrameRate = try reader.readFloat()
        let storedFrameCount = Int(try reader.readUInt32())
        let resizingModeIdentifier = try reader.readUInt64()
        let frameRateConversionModeIdentifier = try reader.readUInt64()
        guard try reader.readUInt32() == CoMotionArchiveFormat.meshSchemaVersion else
        {
            throw CoMotionArchiveReaderError.invalidHeader("mesh schema version changed")
        }
        let modelCompatibilityVersion = try reader.readUInt32()
        let smplCompatibilityVersion = try reader.readUInt32()
        guard try reader.readUInt32() == UInt32(CoMotionArchiveFormat.maximumPeoplePerFrame) else
        {
            throw CoMotionArchiveReaderError.invalidHeader("maximum person count changed")
        }
        let completedFrameCount = Int(try reader.readUInt32())
        let storedFailedFrameCount = Int(try reader.readUInt32())
        let frameIndexOffset = try reader.readUInt64()
        let frameDataOffset = try reader.readUInt64()
        guard try reader.readUInt64() == 0 else
        {
            throw CoMotionArchiveReaderError.invalidHeader("reserved bytes are not zero")
        }

        guard reader.offset == CoMotionArchiveFormat.headerByteCount,
              frameIndexOffset == UInt64(CoMotionArchiveFormat.headerByteCount)
        else
        {
            throw CoMotionArchiveReaderError.invalidHeader("frame index offset changed")
        }
        guard storedFrameCount > 0,
              storedFrameCount <= CoMotionArchiveFormat.maximumFrameCount,
              completedFrameCount == storedFrameCount
        else
        {
            throw CoMotionArchiveReaderError.invalidMetadata("invalid or incomplete frame count")
        }
        guard encodedWidth > 0,
              encodedWidth <= CoMotionArchiveFormat.maximumDimension,
              encodedHeight > 0,
              encodedHeight <= CoMotionArchiveFormat.maximumDimension
        else
        {
            throw CoMotionArchiveReaderError.invalidMetadata("encoded dimensions are outside the supported range")
        }
        guard encodedFrameRate.isFinite,
              encodedFrameRate > 0,
              encodedFrameRate <= CoMotionArchiveFormat.maximumFrameRate
        else
        {
            throw CoMotionArchiveReaderError.invalidMetadata("encoded frame rate is outside the supported range")
        }
        guard modelCompatibilityVersion == CoMotionArchiveFormat.modelCompatibilityVersion,
              smplCompatibilityVersion == CoMotionArchiveFormat.smplCompatibilityVersion
        else
        {
            throw CoMotionArchiveReaderError.invalidMetadata("compatibility versions changed")
        }

        let (frameIndexByteCount, indexOverflow) = storedFrameCount.multipliedReportingOverflow(by: 8)
        let (expectedFrameDataOffset, offsetOverflow) = CoMotionArchiveFormat.headerByteCount
            .addingReportingOverflow(frameIndexByteCount)
        guard indexOverflow == false,
              offsetOverflow == false,
              frameDataOffset == UInt64(expectedFrameDataOffset),
              expectedFrameDataOffset <= data.count
        else
        {
            throw CoMotionArchiveReaderError.invalidHeader("frame data offset changed")
        }

        var decodedFrameOffsets: [Int] = []
        decodedFrameOffsets.reserveCapacity(storedFrameCount)
        for _ in 0 ..< storedFrameCount
        {
            let frameOffset = try reader.readUInt64()
            guard frameOffset <= UInt64(Int.max) else
            {
                throw CoMotionArchiveReaderError.exceedsSizeLimit
            }
            decodedFrameOffsets.append(Int(frameOffset))
        }
        guard reader.offset == expectedFrameDataOffset else
        {
            throw CoMotionArchiveReaderError.invalidHeader("frame index size changed")
        }

        var validatedFailedFrameCount = 0
        var previousSourceFrameIndex: Int?
        for frameIndex in 0 ..< storedFrameCount
        {
            let frameStart = decodedFrameOffsets[frameIndex]
            let frameEnd = frameIndex + 1 < storedFrameCount
                ? decodedFrameOffsets[frameIndex + 1] : data.count
            guard frameStart == (frameIndex == 0
                ? expectedFrameDataOffset : decodedFrameOffsets[frameIndex]),
                frameStart >= expectedFrameDataOffset,
                frameEnd > frameStart,
                frameEnd <= data.count
            else
            {
                throw CoMotionArchiveReaderError.invalidFrame(
                    "offset for frame \(frameIndex) is invalid"
                )
            }
            var frameReader = BinaryReader(data: data, offset: frameStart, limit: frameEnd)
            let ordinal = Int(try frameReader.readUInt32())
            let sourceFrameIndexValue = try frameReader.readUInt64()
            guard sourceFrameIndexValue <= UInt64(Int.max) else
            {
                throw CoMotionArchiveReaderError.invalidFrame("source frame index exceeds Int")
            }
            let sourceFrameIndex = Int(sourceFrameIndexValue)
            let status = try frameReader.readUInt32()
            let personCount = Int(try frameReader.readUInt32())
            let payloadByteCountValue = try frameReader.readUInt64()
            guard payloadByteCountValue <= UInt64(Int.max) else
            {
                throw CoMotionArchiveReaderError.invalidFrame("payload size exceeds Int")
            }
            let payloadByteCount = Int(payloadByteCountValue)
            guard ordinal == frameIndex else
            {
                throw CoMotionArchiveReaderError.invalidFrame(
                    "ordinal \(ordinal) does not match position \(frameIndex)"
                )
            }
            if let previousSourceFrameIndex, sourceFrameIndex < previousSourceFrameIndex
            {
                throw CoMotionArchiveReaderError.invalidFrame(
                    "source frame indexes are not nondecreasing"
                )
            }
            previousSourceFrameIndex = sourceFrameIndex

            switch status
            {
                case CoMotionArchiveFormat.availableStatus:
                    guard personCount <= CoMotionArchiveFormat.maximumPeoplePerFrame,
                          payloadByteCount == personCount * CoMotionArchiveFormat.personRecordByteCount
                    else
                    {
                        throw CoMotionArchiveReaderError.invalidFrame("available payload size changed")
                    }
                    for _ in 0 ..< personCount
                    {
                        let confidence = try frameReader.readFloat()
                        guard confidence.isFinite, confidence >= 0, confidence <= 1 else
                        {
                            throw CoMotionArchiveReaderError.invalidPerson(
                                "confidence must be finite and between zero and one"
                            )
                        }
                        for _ in 0 ..< CoMotionMeshParameters.totalFloatCount
                        {
                            guard try frameReader.readFloat().isFinite else
                            {
                                throw CoMotionArchiveReaderError.invalidPerson(
                                    "mesh parameters contain a non-finite value"
                                )
                            }
                        }
                    }
                case CoMotionArchiveFormat.failedStatus:
                    guard personCount == 0, payloadByteCount == 4,
                          CoMotionFrameFailureCode(rawValue: try frameReader.readUInt32()) != nil
                    else
                    {
                        throw CoMotionArchiveReaderError.invalidFrame("failed frame payload changed")
                    }
                    validatedFailedFrameCount += 1
                default:
                    throw CoMotionArchiveReaderError.invalidFrame("status \(status) is unknown")
            }
            guard frameReader.offset == frameEnd else
            {
                throw CoMotionArchiveReaderError.invalidFrame(
                    "payload size does not match frame boundary"
                )
            }
        }
        guard validatedFailedFrameCount == storedFailedFrameCount else
        {
            throw CoMotionArchiveReaderError.invalidHeader("failed frame count changed")
        }

        self.data = data
        metadata = CoMotionArchiveMetadata(
            videoSourceID: videoSourceID,
            encodedArtifactGeneration: encodedArtifactGeneration,
            encodedWidth: encodedWidth,
            encodedHeight: encodedHeight,
            encodedFrameRate: encodedFrameRate,
            resizingModeIdentifier: resizingModeIdentifier,
            frameRateConversionModeIdentifier: frameRateConversionModeIdentifier,
            modelCompatibilityVersion: modelCompatibilityVersion,
            smplCompatibilityVersion: smplCompatibilityVersion
        )
        frameCount = storedFrameCount
        failedFrameCount = validatedFailedFrameCount
        payloadByteCount = data.count
        frameOffsets = decodedFrameOffsets
    }

    public func frameAtIndex(_ frameIndex: Int) throws -> CoMotionFrame
    {
        guard frameOffsets.indices.contains(frameIndex) else
        {
            throw CoMotionArchiveReaderError.frameOutOfRange(frameIndex)
        }
        let frameEnd = frameIndex + 1 < frameCount ? frameOffsets[frameIndex + 1] : data.count
        var reader = BinaryReader(data: data, offset: frameOffsets[frameIndex], limit: frameEnd)
        let ordinal = Int(try reader.readUInt32())
        let sourceFrameIndex = Int(try reader.readUInt64())
        let status = try reader.readUInt32()
        let personCount = Int(try reader.readUInt32())
        _ = try reader.readUInt64()

        let frameStatus: CoMotionFrameStatus
        switch status
        {
            case CoMotionArchiveFormat.availableStatus:
                var people: [CoMotionFramePerson] = []
                people.reserveCapacity(personCount)
                for _ in 0 ..< personCount
                {
                    let confidence = try reader.readFloat()
                    do
                    {
                        let parameters = try CoMotionMeshParameters(
                            betas: reader.readFloats(CoMotionMeshParameters.betaCount),
                            poseFeature: reader.readFloats(CoMotionMeshParameters.poseFeatureCount),
                            skinningTransforms: reader.readFloats(
                                CoMotionMeshParameters.skinningTransformCount
                            ),
                            translation: reader.readFloats(
                                CoMotionMeshParameters.translationCount
                            )
                        )
                        people.append(
                            CoMotionFramePerson(
                                confidence: confidence,
                                meshParameters: parameters
                            )
                        )
                    }
                    catch
                    {
                        throw CoMotionArchiveReaderError.invalidPerson(
                            error.localizedDescription
                        )
                    }
                }
                frameStatus = .available(people)
            case CoMotionArchiveFormat.failedStatus:
                guard let failureCode = CoMotionFrameFailureCode(
                    rawValue: try reader.readUInt32()
                )
                else
                {
                    throw CoMotionArchiveReaderError.invalidFrame("unknown failure code")
                }
                frameStatus = .failed(failureCode)
            default:
                throw CoMotionArchiveReaderError.invalidFrame("unknown status")
        }
        return CoMotionFrame(
            videoFrameOrdinal: ordinal,
            sourceFrameIndex: sourceFrameIndex,
            status: frameStatus
        )
    }

    public func frameIndex(time: TimeInterval, loop: Bool) -> Int
    {
        guard time.isFinite else { return 0 }
        let requestedFrame = Int((time * TimeInterval(metadata.encodedFrameRate)).rounded(.down))
        if loop
        {
            return ((requestedFrame % frameCount) + frameCount) % frameCount
        }
        return min(max(requestedFrame, 0), frameCount - 1)
    }
}

private struct BinaryReader
{
    let data: Data
    let limit: Int
    var offset: Int

    init(data: Data, offset: Int = 0, limit: Int? = nil)
    {
        self.data = data
        self.offset = offset
        self.limit = limit ?? data.count
    }

    mutating func readUInt32() throws -> UInt32
    {
        guard offset >= 0, offset <= limit, 4 <= limit - offset else
        {
            throw CoMotionArchiveReaderError.truncated
        }
        let value = data.withUnsafeBytes
        { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readUInt64() throws -> UInt64
    {
        guard offset >= 0, offset <= limit, 8 <= limit - offset else
        {
            throw CoMotionArchiveReaderError.truncated
        }
        let value = data.withUnsafeBytes
        { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func readFloat() throws -> Float
    {
        Float(bitPattern: try readUInt32())
    }

    mutating func readFloats(_ count: Int) throws -> [Float]
    {
        var values: [Float] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count
        {
            values.append(try readFloat())
        }
        return values
    }

    mutating func readUUID() throws -> UUID
    {
        guard offset >= 0, offset <= limit, 16 <= limit - offset else
        {
            throw CoMotionArchiveReaderError.truncated
        }
        let bytes = Array(data[offset ..< offset + 16])
        offset += 16
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}
