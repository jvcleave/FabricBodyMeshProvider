import BodyMeshProviderCore
import Foundation
import os

enum BodyMeshProviderResourceError: LocalizedError
{
    case missingMeshConstants
    case invalidMotionArchiveURL
    case invalidMotionFrame

    var errorDescription: String?
    {
        switch self
        {
            case .missingMeshConstants:
                return "CoMotionMeshConstants.bin is missing from the Body Mesh Provider plug-in."
            case .invalidMotionArchiveURL:
                return "Choose a local CoMotion archive file or a folder containing frames.bin."
            case .invalidMotionFrame:
                return "The CoMotion Frame input does not contain a valid motion frame."
        }
    }
}

enum BodyMeshProviderResources
{
    private static let meshReconstructorResult: Result<CoMotionMeshReconstructor, Error> = Result
    {
        guard let constantsURL = Bundle(for: BodyMeshProviderPlugin.self).url(
            forResource: "CoMotionMeshConstants",
            withExtension: "bin"
        )
        else
        {
            throw BodyMeshProviderResourceError.missingMeshConstants
        }

        let constantsData = try Data(contentsOf: constantsURL, options: .mappedIfSafe)
        return try CoMotionMeshReconstructor(constantsData: constantsData)
    }

    static func meshReconstructor() throws -> CoMotionMeshReconstructor
    {
        try meshReconstructorResult.get()
    }

    static func resolveFileURL(_ url: URL?, relativeTo directory: URL?) -> URL?
    {
        guard let url, url.scheme == nil, let directory,
              let resolved = URL(string: url.relativeString, relativeTo: directory)?.absoluteURL
        else { return url }
        return resolved.standardizedFileURL
    }

    static func motionArchive(_ url: URL) throws -> CoMotionArchiveReader
    {
        guard url.isFileURL else { throw BodyMeshProviderResourceError.invalidMotionArchiveURL }
        return try waitForSource {
            let fileURL = url.resolvingSymlinksInPath()
            let properties = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if properties.isDirectory == true
            {
                let archive = try CoMotionArchiveReader(directoryURL: fileURL)
                let descriptor = try BodyMeshAssetDescriptor.loadIfPresent(directoryURL: fileURL)
                try descriptor?.validate(archiveReader: archive)
                return archive
            }
            guard properties.isRegularFile == true, url.pathExtension.lowercased() == "bin"
            else { throw BodyMeshProviderResourceError.invalidMotionArchiveURL }
            if let size = properties.fileSize, size > CoMotionArchiveFormat.maximumArchiveByteCount
            {
                throw CoMotionArchiveReaderError.exceedsSizeLimit
            }
            return try CoMotionArchiveReader(data: Data(contentsOf: fileURL, options: .mappedIfSafe))
        }
    }

    static func waitForSource<Value: Sendable>(_ load: @escaping @Sendable () async throws -> Value) throws -> Value
    {
        let completed = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<Value, any Error>?>(initialState: nil)
        // Fabric draws immediately after cold graph startup. Only a changed
        // source waits for preparation. The worker never calls back into Fabric.
        Task.detached(priority: .userInitiated) {
            defer { completed.signal() }
            do
            {
                let value = try await load()
                result.withLock { $0 = .success(value) }
            }
            catch { result.withLock { $0 = .failure(error) } }
        }
        completed.wait()
        guard let loaded = result.withLock({ $0 })
        else { throw CharacterModelError.resources("The source worker did not return a result.") }
        return try loaded.get()
    }
}
