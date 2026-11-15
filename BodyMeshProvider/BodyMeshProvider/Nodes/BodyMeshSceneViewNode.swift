import Fabric
import Foundation
import Metal
import Satin
import simd

public final class BodyMeshSceneViewNode: ObjectNode<Object>
{
    public override class var name: String { "Body Mesh View" }
    public override class var nodeType: Node.NodeType { .Object(objectType: .Mesh) }
    public override class var nodeDescription: String { "Place and pose a selected USDZ character using shared CoMotion frames." }

    private struct ModelRequest: Equatable
    {
        let characterA: String?
        let characterB: String?
        let directory: URL?
    }

    private lazy var captureSpace = Object(context: context, label: "Body Mesh Capture Space")
    private lazy var sceneObject: Object = {
        let root = Object(context: context, label: Self.name)
        root.add(captureSpace)
        return root
    }()

    private var modelRequest: ModelRequest?
    private var modelURLs: [URL?] = []
    private var preparedModels: [URL: Result<CharacterModelRenderable, any Error>] = [:]
    private var activeModel: CharacterModelRenderable?
    private var motionFrame: CoMotionFramePayload?
    private var didReadMotionFrame = false
    private var lastSelection: BodyMeshFrameSelection?
    private var boundingBox: Mesh?

    public override var object: Object? { sceneObject }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        let objectPorts = super.registerPorts(context: context)
        for (name, port) in objectPorts where name == "inputOrientation"
        {
            (port.parameter as? Float4Parameter)?.value = BodyMeshIntrinsicCameraNode.defaultOrientation
        }
        return [
            (
                "inputCharacterA",
                NodePort<String>(name: "Character A", kind: .Inlet, description: "Model reference for index 0")
            ),
            (
                "inputCharacterB",
                NodePort<String>(name: "Character B", kind: .Inlet, description: "Model reference for index 1")
            ),
            (
                "inputCharacterIndex",
                ParameterPort(parameter: IntParameter("Character Index", 0, 0, 1, .inputfield, "Index of the model to draw"))
            ),
            (
                "inputCoMotionFrame",
                NodePort<CoMotionFramePayload.Values>(
                    name: "CoMotion Frame", kind: .Inlet, description: "Detections and pose parameters from CoMotion Data"
                )
            ),
            (
                "inputCameraDistance",
                ParameterPort(parameter: FloatParameter(
                    "Camera Distance", 0, .inputfield, "Distance from the capture eye to the view pivot in scene units"
                ))
            ),
            (
                "inputDrawBoundingBox",
                ParameterPort(parameter: BoolParameter(
                    "Draw Bounding Box", false, .toggle, "Draw the bounds of the visible posed character"
                ))
            ),
            (
                "outputCameraTransform",
                NodePort<simd_float4x4>(
                    name: "Camera Transform", kind: .Outlet, description: "World transform of the capture eye"
                )
            ),
        ] + BodyMeshPlaybackPorts.selectionInputs() + objectPorts
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        captureSpace.removeAll()
        modelRequest = nil
        modelURLs.removeAll()
        preparedModels.removeAll()
        activeModel = nil
        motionFrame = nil
        didReadMotionFrame = false
        lastSelection = nil
        boundingBox = nil
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let distancePort: ParameterPort<Float> = port(named: "inputCameraDistance")
        let distance = distancePort.value ?? 0
        let position = inputPosition.value ?? .zero
        let scale = inputScale.value ?? .one
        let orientationLength = simd_length_squared(inputOrientation.value ?? BodyMeshIntrinsicCameraNode.defaultOrientation)
        guard distance.isFinite, distance >= 0, position.x.isFinite, position.y.isFinite, position.z.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite, scale.x > 0, scale.y > 0, scale.z > 0,
              orientationLength.isFinite, orientationLength > 0
        else
        {
            throw FabricError(
                .execution(.failed),
                severity: .recoverable,
                message: "Body Mesh View requires a finite position, valid orientation, positive scale, and nonnegative camera distance."
            )
        }
        _ = evaluate(object: sceneObject, atTime: executionInfo.timing.time)
        if captureSpace.position.z != distance { captureSpace.position = SIMD3(0, 0, distance) }
        let cameraTransform: NodePort<simd_float4x4> = port(named: "outputCameraTransform")
        cameraTransform.send(captureSpace.worldMatrix)

        let loadError = prepareModels()
        selectModel()
        defer { updateBoundingBox() }
        do
        {
            try updateMotionFrame()
            if let activeModel, let motionFrame
            {
                let selection = BodyMeshFrameSelection(node: self, frameIndex: motionFrame.frameIndex)
                if lastSelection != selection
                {
                    try activeModel.prepare(selection.select(motionFrame.people))
                    lastSelection = selection
                }
                try activeModel.encode(commandBuffer: commandBuffer)
            }
        }
        catch
        {
            activeModel?.clear()
            lastSelection = nil
            throw FabricError(.execution(.failed), severity: .recoverable, message: error.localizedDescription, underlyingError: error)
        }
        if let loadError
        {
            throw FabricError(
                .execution(.failed), severity: .recoverable, message: loadError.localizedDescription, underlyingError: loadError
            )
        }
    }

    private func prepareModels() -> (any Error)?
    {
        let characterA: NodePort<String> = port(named: "inputCharacterA")
        let characterB: NodePort<String> = port(named: "inputCharacterB")
        let request = ModelRequest(characterA: characterA.value, characterB: characterB.value, directory: graph?.fileReferenceBaseURL)
        guard modelRequest != request else { return nil }
        modelRequest = request

        var loadError: (any Error)?
        modelURLs = [request.characterA, request.characterB].map { reference in
            guard let reference, !reference.isEmpty else { return nil }
            guard let url = URL(fileReference: reference, relativeTo: request.directory), url.pathExtension.lowercased() == "usdz"
            else
            {
                loadError = CharacterModelError.resources("Choose a local mapped Creator USDZ for Body Mesh View.")
                return nil
            }
            return url
        }
        let requestedURLs = Set(modelURLs.compactMap { $0 })
        for url in preparedModels.keys where !requestedURLs.contains(url)
        {
            if let prepared = preparedModels.removeValue(forKey: url), case let .success(model) = prepared
            {
                captureSpace.remove(model.object)
            }
        }

        for case let url? in modelURLs where preparedModels[url] == nil
        {
            let prepared = Result { try CharacterModelRenderable(context: context, sourceURL: url) }
            preparedModels[url] = prepared
            switch prepared
            {
                case .success(let model):
                    model.object.visible = false
                    captureSpace.add(model.object)
                case .failure(let error):
                    if loadError == nil { loadError = error }
            }
        }
        return loadError
    }

    private func selectModel()
    {
        let indexPort: ParameterPort<Int> = port(named: "inputCharacterIndex")
        let index = indexPort.value ?? 0
        let url = modelURLs.indices.contains(index) ? modelURLs[index] : nil
        let model = url.flatMap { try? preparedModels[$0]?.get() }
        guard activeModel !== model else { return }
        activeModel?.object.visible = false
        activeModel = model
        lastSelection = nil
    }

    private func updateMotionFrame() throws
    {
        let input: NodePort<CoMotionFramePayload.Values> = port(named: "inputCoMotionFrame")
        guard !didReadMotionFrame || input.valueDidChange else { return }
        didReadMotionFrame = true
        motionFrame = nil
        lastSelection = nil
        if let values = input.value, !values.isEmpty
        {
            motionFrame = try CoMotionFramePayload(values: values)
        }
        else
        {
            activeModel?.clear()
        }
    }

    private func updateBoundingBox()
    {
        let draw: ParameterPort<Bool> = port(named: "inputDrawBoundingBox")
        guard draw.value == true, sceneObject.visible, let bounds = activeModel?.captureBounds
        else
        {
            boundingBox?.visible = false
            return
        }
        let size = bounds.max - bounds.min
        guard size.x.isFinite, size.y.isFinite, size.z.isFinite, size.x > 0, size.y > 0, size.z > 0
        else
        {
            boundingBox?.visible = false
            return
        }

        let mesh: Mesh
        if let boundingBox { mesh = boundingBox }
        else
        {
            mesh = makeBoundingBox()
            captureSpace.add(mesh)
            boundingBox = mesh
        }
        let center = bounds.min + 0.5 * size
        if mesh.position != center { mesh.position = center }
        if mesh.scale != size { mesh.scale = size }
        mesh.visible = true
    }

    private func makeBoundingBox() -> Mesh
    {
        let corners: [SIMD3<Float>] = [
            [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5],
            [-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5],
        ]
        let indices = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
        let geometry = Geometry(context: context, primitiveType: .line)
        geometry.addAttribute(Float3BufferAttribute(defaultValue: .zero, data: indices.map { corners[$0] }), for: .Position)
        let material = BasicColorMaterial(context: context, color: [0.2, 0.9, 1, 1])
        material.depthWriteEnabled = false
        let mesh = Mesh(context: context, label: "Body Mesh Bounding Box", geometry: geometry, material: material)
        mesh.castShadow = false
        return mesh
    }
}
