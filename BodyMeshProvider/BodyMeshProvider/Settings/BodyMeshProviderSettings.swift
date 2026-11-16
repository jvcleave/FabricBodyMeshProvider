import Fabric
import Foundation

public struct BodyMeshProviderSettings: Codable, Equatable, Sendable
{
    public var assetFolderURLString: String
    var storeAbsolutePath: Bool?

    public init(assetFolderURL: URL? = nil)
    {
        assetFolderURLString = assetFolderURL?.standardizedFileURL.absoluteString ?? ""
    }

    func assetFolderURL(relativeTo directory: URL?) -> URL?
    {
        URL(fileReference: assetFolderURLString, relativeTo: directory, directoryHint: .isDirectory)
    }

    func savingAssetFolder(relativeTo directory: URL?) -> Self
    {
        // Existing relative references follow the scene, as file-picker ports do.
        let sourceDirectory = storeAbsolutePath == true ? directory : nil
        guard let absoluteURL = assetFolderURL(relativeTo: sourceDirectory) else { return self }
        var settings = self
        settings.setAssetFolder(absoluteURL, relativeTo: directory)
        return settings
    }

    mutating func setAssetFolder(_ url: URL, relativeTo directory: URL?)
    {
        assetFolderURLString = url.fileReference(relativeTo: storeAbsolutePath == true ? nil : directory)
    }
}
