import XCTest
@testable import BodyMeshProviderCore

final class CoMotionArchiveReaderTests: XCTestCase
{
    func testReadsIndexedAvailableAndFailedFrames() throws
    {
        let archiveData = try makeArchiveData()
        let archiveReader = try CoMotionArchiveReader(data: archiveData)

        XCTAssertEqual(archiveReader.frameCount, 2)
        XCTAssertEqual(archiveReader.failedFrameCount, 1)
        XCTAssertEqual(archiveReader.payloadByteCount, archiveData.count)
        XCTAssertEqual(archiveReader.metadata.encodedWidth, 1920)
        XCTAssertEqual(archiveReader.metadata.encodedHeight, 1080)
        XCTAssertEqual(archiveReader.metadata.encodedFrameRate, 60)

        let availableFrame = try archiveReader.frameAtIndex(0)
        XCTAssertEqual(availableFrame.videoFrameOrdinal, 0)
        XCTAssertEqual(availableFrame.sourceFrameIndex, 10)
        guard case let .available(people) = availableFrame.status else
        {
            return XCTFail("Expected an available frame")
        }
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].confidence, 0.75)
        XCTAssertEqual(people[0].meshParameters.betas.count, 10)
        XCTAssertEqual(people[0].meshParameters.poseFeature.count, 207)
        XCTAssertEqual(people[0].meshParameters.skinningTransforms.count, 384)
        XCTAssertEqual(people[0].meshParameters.translation, [1, 2, 3])

        let failedFrame = try archiveReader.frameAtIndex(1)
        XCTAssertEqual(failedFrame.videoFrameOrdinal, 1)
        XCTAssertEqual(failedFrame.sourceFrameIndex, 11)
        XCTAssertEqual(failedFrame.status, .failed(.prediction))
    }

    func testResolvesLoopedAndClampedFrameIndexes() throws
    {
        let archiveReader = try CoMotionArchiveReader(data: makeArchiveData())

        XCTAssertEqual(archiveReader.frameIndex(time: 0, loop: true), 0)
        XCTAssertEqual(archiveReader.frameIndex(time: 1.0 / 60.0, loop: true), 1)
        XCTAssertEqual(archiveReader.frameIndex(time: 2.0 / 60.0, loop: true), 0)
        XCTAssertEqual(archiveReader.frameIndex(time: -1.0 / 60.0, loop: true), 1)
        XCTAssertEqual(archiveReader.frameIndex(time: -1, loop: false), 0)
        XCTAssertEqual(archiveReader.frameIndex(time: 10, loop: false), 1)
    }

    func testRejectsUnsupportedFormatVersion() throws
    {
        var archiveData = try makeArchiveData()
        replaceUInt32(99, at: 4, in: &archiveData)

        XCTAssertThrowsError(try CoMotionArchiveReader(data: archiveData))
        { error in
            XCTAssertEqual(
                error as? CoMotionArchiveReaderError,
                .invalidHeader("format version changed")
            )
        }
    }

    func testRejectsTruncatedFrame() throws
    {
        let archiveData = try makeArchiveData().dropLast()

        XCTAssertThrowsError(try CoMotionArchiveReader(data: Data(archiveData)))
    }

    func testRejectsInvalidFirstFrameOffset() throws
    {
        var archiveData = try makeArchiveData()
        replaceUInt64(145, at: 128, in: &archiveData)

        XCTAssertThrowsError(try CoMotionArchiveReader(data: archiveData))
    }

    func testRejectsTooManyPeople() throws
    {
        var archiveData = try makeArchiveData()
        replaceUInt32(9, at: 160, in: &archiveData)

        XCTAssertThrowsError(try CoMotionArchiveReader(data: archiveData))
    }

    func testRejectsNonFiniteConfidence() throws
    {
        var archiveData = try makeArchiveData()
        replaceUInt32(Float.nan.bitPattern, at: 172, in: &archiveData)

        XCTAssertThrowsError(try CoMotionArchiveReader(data: archiveData))
    }

    func testDescriptorValidatesArchivePayloadByteCount() throws
    {
        let archiveData = try makeArchiveData()
        let archiveReader = try CoMotionArchiveReader(data: archiveData)
        let matchingDescriptor = try makeDescriptor(
            payloadByteCount: archiveData.count
        )

        XCTAssertNoThrow(try matchingDescriptor.validate(archiveReader: archiveReader))

        let mismatchedDescriptor = try makeDescriptor(
            payloadByteCount: archiveData.count + 1
        )
        XCTAssertThrowsError(
            try mismatchedDescriptor.validate(archiveReader: archiveReader)
        )
        { error in
            XCTAssertEqual(
                error as? BodyMeshAssetDescriptorError,
                .payloadMismatch
            )
        }
    }

    func testReadsLocalSampleDataWhenPresent() throws
    {
        let sampleDataURL = repositoryURL.appending(path: "SampleData")
        let sampleDirectoryURLs = try FileManager.default.contentsOfDirectory(
            at: sampleDataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter
        { directoryURL in
            FileManager.default.fileExists(
                atPath: directoryURL.appending(path: "frames.bin").path
            )
        }
        guard sampleDirectoryURLs.isEmpty == false else
        {
            throw XCTSkip("Local SampleData is not installed")
        }

        for sampleDirectoryURL in sampleDirectoryURLs
        {
            let archiveReader = try CoMotionArchiveReader(directoryURL: sampleDirectoryURL)
            let descriptor = try XCTUnwrap(
                BodyMeshAssetDescriptor.loadIfPresent(directoryURL: sampleDirectoryURL),
                "Missing descriptor in \(sampleDirectoryURL.lastPathComponent)"
            )
            try descriptor.validate(archiveReader: archiveReader)

            for frameIndex in [0, archiveReader.frameCount / 2, archiveReader.frameCount - 1]
            {
                XCTAssertEqual(
                    try archiveReader.frameAtIndex(frameIndex).videoFrameOrdinal,
                    frameIndex,
                    sampleDirectoryURL.lastPathComponent
                )
            }
        }
    }

    func testReadsIncludedFabricSceneAsset() throws
    {
        let assetDirectoryURL = repositoryURL
            .appending(path: "FabricScenes")
            .appending(path: "947B44F8-C4C3-4666-93B5-73BD71CE231A")
        let archiveReader = try CoMotionArchiveReader(
            directoryURL: assetDirectoryURL
        )
        let descriptor = try XCTUnwrap(
            BodyMeshAssetDescriptor.loadIfPresent(
                directoryURL: assetDirectoryURL
            )
        )

        try descriptor.validate(archiveReader: archiveReader)
        XCTAssertEqual(descriptor.name, "24sectest")
        XCTAssertEqual(archiveReader.frameCount, 1_461)
        for frameIndex in [0, archiveReader.frameCount / 2, archiveReader.frameCount - 1]
        {
            XCTAssertEqual(
                try archiveReader.frameAtIndex(frameIndex).videoFrameOrdinal,
                frameIndex
            )
        }
    }

    private func makeArchiveData() throws -> Data
    {
        let firstFrameOffset = 128 + 16
        let availablePayloadByteCount = CoMotionArchiveFormat.personRecordByteCount
        let firstFrameByteCount = 28 + availablePayloadByteCount
        let secondFrameOffset = firstFrameOffset + firstFrameByteCount

        var data = Data()
        appendUInt32(0x434D5343, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(128, to: &data)
        appendUInt32(1, to: &data)
        appendUUID(
            try XCTUnwrap(
                UUID(uuidString: "6D575260-D532-4FC9-B02E-486686BE6406")
            ),
            to: &data
        )
        appendUUID(
            try XCTUnwrap(
                UUID(uuidString: "4B81C970-9B48-4E4D-BD2B-53EC40E44EC5")
            ),
            to: &data
        )
        appendUInt32(1920, to: &data)
        appendUInt32(1080, to: &data)
        appendFloat(60, to: &data)
        appendUInt32(2, to: &data)
        appendUInt64(6571808415355174537, to: &data)
        appendUInt64(18370659580675755574, to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(8, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(1, to: &data)
        appendUInt64(128, to: &data)
        appendUInt64(UInt64(firstFrameOffset), to: &data)
        appendUInt64(0, to: &data)
        XCTAssertEqual(data.count, 128)

        appendUInt64(UInt64(firstFrameOffset), to: &data)
        appendUInt64(UInt64(secondFrameOffset), to: &data)

        appendUInt32(0, to: &data)
        appendUInt64(10, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(1, to: &data)
        appendUInt64(UInt64(availablePayloadByteCount), to: &data)
        appendFloat(0.75, to: &data)
        for _ in 0 ..< CoMotionMeshParameters.betaCount
        {
            appendFloat(0, to: &data)
        }
        for _ in 0 ..< CoMotionMeshParameters.poseFeatureCount
        {
            appendFloat(0, to: &data)
        }
        for _ in 0 ..< CoMotionMeshParameters.skinningTransformCount
        {
            appendFloat(0, to: &data)
        }
        appendFloat(1, to: &data)
        appendFloat(2, to: &data)
        appendFloat(3, to: &data)

        appendUInt32(1, to: &data)
        appendUInt64(11, to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(0, to: &data)
        appendUInt64(4, to: &data)
        appendUInt32(CoMotionFrameFailureCode.prediction.rawValue, to: &data)
        return data
    }

    private func makeDescriptor(payloadByteCount: Int) throws -> BodyMeshAssetDescriptor
    {
        let videoSourceID = try XCTUnwrap(
            UUID(uuidString: "6D575260-D532-4FC9-B02E-486686BE6406")
        )
        let artifactGeneration = try XCTUnwrap(
            UUID(uuidString: "4B81C970-9B48-4E4D-BD2B-53EC40E44EC5")
        )
        return BodyMeshAssetDescriptor(
            descriptorVersion: BodyMeshAssetDescriptor.currentVersion,
            id: UUID(),
            kind: "coMotionSMPL",
            name: "Fixture",
            createdAt: .distantPast,
            width: 1920,
            height: 1080,
            frameRate: 60,
            frameCount: 2,
            failedFrameCount: 1,
            payloadFileName: BodyMeshAssetDescriptor.payloadFileName,
            payloadByteCount: payloadByteCount,
            thumbnailFileName: nil,
            originDisplayName: nil,
            originVideoSourceID: videoSourceID,
            originEncodedArtifactGeneration: artifactGeneration,
            resizingModeIdentifier: 6571808415355174537,
            frameRateConversionModeIdentifier: 18370659580675755574,
            payloadFormatVersion: CoMotionArchiveFormat.formatVersion,
            meshSchemaVersion: CoMotionArchiveFormat.meshSchemaVersion,
            modelCompatibilityVersion: CoMotionArchiveFormat.modelCompatibilityVersion,
            smplCompatibilityVersion: CoMotionArchiveFormat.smplCompatibilityVersion
        )
    }

    private var repositoryURL: URL
    {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data)
    {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue)
        { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data)
    {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue)
        { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func appendFloat(_ value: Float, to data: inout Data)
    {
        appendUInt32(value.bitPattern, to: &data)
    }

    private func appendUUID(_ value: UUID, to data: inout Data)
    {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes)
        { rawBytes in
            data.append(contentsOf: rawBytes)
        }
    }

    private func replaceUInt32(_ value: UInt32, at offset: Int, in data: inout Data)
    {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue)
        { bytes in
            data.replaceSubrange(offset ..< offset + 4, with: bytes)
        }
    }

    private func replaceUInt64(_ value: UInt64, at offset: Int, in data: inout Data)
    {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue)
        { bytes in
            data.replaceSubrange(offset ..< offset + 8, with: bytes)
        }
    }
}
