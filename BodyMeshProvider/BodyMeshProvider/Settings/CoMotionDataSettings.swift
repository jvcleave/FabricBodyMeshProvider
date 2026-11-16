import Fabric
import Foundation

public struct CoMotionDataSettings: NodeSettings
{
    public var motionArchiveURL: URL?
    var storeAbsoluteArchivePath: Bool?

    public init(motionArchiveURL: URL? = nil)
    {
        self.motionArchiveURL = motionArchiveURL
    }

    func resolvingArchive(relativeTo directory: URL?) -> Self
    {
        Self(motionArchiveURL: BodyMeshProviderResources.resolveFileURL(motionArchiveURL, relativeTo: directory))
    }

    func savingArchive(relativeTo directory: URL?) -> Self
    {
        var settings = self
        settings.motionArchiveURL = BodyMeshProviderResources.fileURLForSaving(
            motionArchiveURL,
            relativeTo: directory,
            storeAbsolutePath: storeAbsoluteArchivePath == true
        )
        return settings
    }
}
