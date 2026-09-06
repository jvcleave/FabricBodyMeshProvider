import Fabric
import Foundation

/// Entry point discovered when Fabric loads the plug-in bundle.
public final class BodyMeshProviderPlugin: NSObject, FabricPlugin
{
    public static func pluginDidLoad(bundle: Bundle) {}

    public static func pluginWillUnload() {}

    public static func additionalNodeClasses() -> [Node.Type]
    {
        [
            BodyMeshProviderNode.self,
            BodyMeshIntrinsicCameraNode.self,
        ]
    }
}
