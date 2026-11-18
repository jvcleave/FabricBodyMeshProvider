import BodyMeshProviderCore
import Fabric
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

    private static let defaultHumanImport = Task.detached(priority: .userInitiated) {
        guard let url = Bundle(for: BodyMeshProviderPlugin.self).url(forResource: "DefaultHuman", withExtension: "usdz")
        else { throw CharacterModelError.resources("The default Human USDZ is missing.") }
        return try await CharacterModelImport.load(url)
    }

    static func defaultHumanModel() throws -> CharacterModelImport
    {
        try waitForSource { try await defaultHumanImport.value }
    }

    static func resolveFileURL(_ url: URL?, relativeTo directory: URL?) -> URL?
    {
        guard let url, url.scheme == nil, let directory,
              let resolved = URL(string: url.relativeString, relativeTo: directory)?.absoluteURL
        else { return url }
        return resolved.standardizedFileURL
    }

    static func fileURLForSaving(_ url: URL?, relativeTo directory: URL?, storeAbsolutePath: Bool) -> URL?
    {
        guard let url, let resolvedURL = resolveFileURL(url, relativeTo: directory), resolvedURL.isFileURL
        else { return url }
        if storeAbsolutePath { return resolvedURL.standardizedFileURL }
        // Keep existing relative URLs as written. They travel with the scene.
        guard url.isFileURL || url.relativeString.hasPrefix("/") else { return url }

        let reference = resolvedURL.fileReference(relativeTo: directory)
        guard !reference.hasPrefix("file://") else { return resolvedURL.standardizedFileURL }

        // These settings encode URLs. Escape literal percent signs and colons
        // so the relative path also decodes as a URL on older plug-in builds.
        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%:"))
        guard let encodedPath = reference.addingPercentEncoding(withAllowedCharacters: allowedCharacters),
              let relativeURL = URL(string: encodedPath)
        else { return resolvedURL.standardizedFileURL }
        return relativeURL
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
