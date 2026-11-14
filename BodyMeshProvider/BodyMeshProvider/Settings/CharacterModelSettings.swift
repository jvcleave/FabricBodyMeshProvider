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

    func resolvingArchive(relativeTo directory: URL?) -> Self
    {
        guard let motionArchiveURL, motionArchiveURL.scheme == nil, let directory,
              let archive = URL(string: motionArchiveURL.relativeString, relativeTo: directory)?.absoluteURL
        else { return self }

        return Self(characterModelURL: characterModelURL, motionArchiveURL: archive.standardizedFileURL)
    }
}
