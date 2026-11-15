import Fabric
import Foundation

public struct CoMotionDataSettings: NodeSettings
{
    public var motionArchiveURL: URL?

    public init(motionArchiveURL: URL? = nil)
    {
        self.motionArchiveURL = motionArchiveURL
    }

    func resolvingArchive(relativeTo directory: URL?) -> Self
    {
        Self(motionArchiveURL: BodyMeshProviderResources.resolveFileURL(motionArchiveURL, relativeTo: directory))
    }
}
