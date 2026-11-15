import Fabric
import Metal
import Satin
import simd

public final class BodyMeshViewNode: SubgraphNode
{
    public override class var name: String { "Body Mesh View Group" }
    public override class var nodeDescription: String { "Place live characters and their source camera together." }
    public override var nodeExecutionMode: Node.ExecutionMode { .Consumer }

    private lazy var viewRoot = Object(context: context, label: Self.name)

    public override var object: Object?
    {
        if let scene = super.object, !viewRoot.children.contains(where: { $0 === scene })
        {
            viewRoot.add(scene)
        }
        return viewRoot
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + [
            (
                "inputPosition",
                ParameterPort(parameter: Float3Parameter("Position", .zero, .inputfield, "Position of the view pivot"))
            ),
            (
                "inputOrientation",
                ParameterPort(parameter: Float4Parameter(
                    "Orientation", BodyMeshIntrinsicCameraNode.defaultOrientation, .inputfield, "View orientation as a quaternion"
                ))
            ),
            (
                "inputScale",
                ParameterPort(parameter: FloatParameter("Scale", 1, .inputfield, "Uniform scale of the view"))
            ),
            (
                "inputCameraDistance",
                ParameterPort(parameter: FloatParameter(
                    "Camera Distance", 0, .inputfield, "Distance from the source camera to the view pivot in scene units"
                ))
            ),
        ]
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let positionPort: ParameterPort<SIMD3<Float>> = port(named: "inputPosition")
        let orientationPort: ParameterPort<SIMD4<Float>> = port(named: "inputOrientation")
        let scalePort: ParameterPort<Float> = port(named: "inputScale")
        let distancePort: ParameterPort<Float> = port(named: "inputCameraDistance")
        let position = positionPort.value ?? .zero
        let orientation = orientationPort.value ?? BodyMeshIntrinsicCameraNode.defaultOrientation
        let orientationLengthSquared = simd_length_squared(orientation)
        let scale = scalePort.value ?? 1
        let distance = distancePort.value ?? 0
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              orientationLengthSquared.isFinite, orientationLengthSquared > 0,
              scale.isFinite, scale > 0, distance.isFinite, distance >= 0
        else
        {
            throw FabricError(
                .execution(.failed),
                severity: .recoverable,
                message: "Body Mesh View requires a finite position, a valid orientation, positive scale, and nonnegative camera distance."
            )
        }

        viewRoot.position = position
        viewRoot.orientation = simd_quatf(vector: orientation / sqrt(orientationLengthSquared))
        viewRoot.scale = SIMD3(repeating: scale)
        // The capture eye starts at the subgraph's origin. Move the scene and
        // its camera together to place the pivot farther into the capture.
        super.object?.position = SIMD3(0, 0, distance)
        try super.execute(
            renderer: renderer,
            executionInfo: executionInfo,
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer
        )
    }
}
