import Fabric
import Foundation

public struct CharacterModelSettings: NodeSettings
{
    /// Nil selects the built-in CoMotion body. A URL selects an imported rig.
    public var characterModelURL: URL?
    public var motionArchiveURL: URL?
    var storeAbsoluteModelPath: Bool?
    var storeAbsoluteArchivePath: Bool?

    public init(characterModelURL: URL? = nil, motionArchiveURL: URL? = nil)
    {
        self.characterModelURL = characterModelURL
        self.motionArchiveURL = motionArchiveURL
    }

    func resolvingSources(relativeTo directory: URL?) -> Self
    {
        var settings = self
        settings.characterModelURL = BodyMeshProviderResources.resolveFileURL(characterModelURL, relativeTo: directory)
        settings.motionArchiveURL = BodyMeshProviderResources.resolveFileURL(motionArchiveURL, relativeTo: directory)
        return settings
    }

    func savingSources(relativeTo directory: URL?) -> Self
    {
        var settings = self
        settings.characterModelURL = BodyMeshProviderResources.fileURLForSaving(
            characterModelURL,
            relativeTo: directory,
            storeAbsolutePath: storeAbsoluteModelPath == true
        )
        settings.motionArchiveURL = BodyMeshProviderResources.fileURLForSaving(
            motionArchiveURL,
            relativeTo: directory,
            storeAbsolutePath: storeAbsoluteArchivePath == true
        )
        return settings
    }
}
