import Fabric
import Metal
import Satin
import simd

public final class BodyMeshViewCameraNode: BodyMeshIntrinsicCameraNode
{
    public override class var name: String { "Body Mesh View Camera" }
    public override class var nodeDescription: String { "Frame CoMotion playback from a Body Mesh View's capture eye." }

    private var followsView = false

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        [
            (
                "inputCameraTransform",
                NodePort<simd_float4x4>(
                    name: "Camera Transform", kind: .Inlet, description: "Connect Camera Transform from Body Mesh View"
                )
            ),
        ] + super.registerPorts(context: context)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let transformPort: NodePort<simd_float4x4> = port(named: "inputCameraTransform")
        let viewTransform = transformPort.value
        if let viewTransform
        {
            let determinant = simd_determinant(viewTransform)
            guard determinant.isFinite, determinant != 0
            else
            {
                throw FabricError(.execution(.failed), severity: .recoverable, message: "Camera Transform must be finite and invertible.")
            }
        }
        else if followsView
        {
            applyLocalPose()
        }
        try super.execute(
            renderer: renderer,
            executionInfo: executionInfo,
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer
        )
        if let viewTransform, object?.worldMatrix != viewTransform
        {
            object?.worldMatrix = viewTransform
        }
        followsView = viewTransform != nil
    }
}
