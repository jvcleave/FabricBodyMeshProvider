import Foundation

public struct BodyMeshProviderSettings: Codable, Equatable, Sendable
{
    public var assetFolderURLString: String

    public init(assetFolderURL: URL? = nil)
    {
        assetFolderURLString = assetFolderURL?.standardizedFileURL.absoluteString ?? ""
    }

    var assetFolderURL: URL?
    {
        guard assetFolderURLString.isEmpty == false else { return nil }
        return URL(string: assetFolderURLString)?.standardizedFileURL
    }
}
