import Fabric
import Foundation

public struct CharacterModelSettings: NodeSettings
{
    /// Nil selects the built-in CoMotion body. A URL selects an imported rig.
    public var characterModelURL: URL?
    public var motionArchiveURL: URL?

    public init(characterModelURL: URL? = nil, motionArchiveURL: URL? = nil)
    {
        self.characterModelURL = characterModelURL
        self.motionArchiveURL = motionArchiveURL
    }

    func resolvingSources(relativeTo directory: URL?) -> Self
    {
        Self(
            characterModelURL: BodyMeshProviderResources.resolveFileURL(characterModelURL, relativeTo: directory),
            motionArchiveURL: BodyMeshProviderResources.resolveFileURL(motionArchiveURL, relativeTo: directory)
        )
    }
}
