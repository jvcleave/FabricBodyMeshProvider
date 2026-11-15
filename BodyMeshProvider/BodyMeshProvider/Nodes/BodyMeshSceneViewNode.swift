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

    private struct CharacterSlot
    {
        let url: URL
        let overrides: CharacterOverrides
    }

    private struct PreparedModel
    {
        let source: CharacterModelSource
        let renderable: Result<CharacterModelRenderable, any Error>
    }

    private lazy var captureSpace = Object(context: context, label: "Body Mesh Capture Space")
    private lazy var sceneObject: Object = {
        let root = Object(context: context, label: Self.name)
        root.add(captureSpace)
        return root
    }()

    private var characterDirectory: URL?
    private var characters: [CharacterSlot?] = []
    private var preparedModels: [URL: PreparedModel] = [:]
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
                NodePort<PortValue>(name: "Character A", kind: .Inlet, description: "Character asset or inspector output for index 0")
            ),
            (
                "inputCharacterB",
                NodePort<PortValue>(name: "Character B", kind: .Inlet, description: "Character asset or inspector output for index 1")
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
        characterDirectory = nil
        characters.removeAll()
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
        let characterA: NodePort<PortValue> = port(named: "inputCharacterA")
        let characterB: NodePort<PortValue> = port(named: "inputCharacterB")
        let directory = graph?.fileReferenceBaseURL
        guard characters.isEmpty || characterDirectory != directory || characterA.valueDidChange || characterB.valueDidChange
        else { return nil }
        characterDirectory = directory

        var loadError: (any Error)?
        characters = [characterA.value, characterB.value].map { value in
            do
            {
                guard let reference = try CharacterReference(value: value) else { return nil }
                return CharacterSlot(url: try reference.fileURL(relativeTo: directory), overrides: reference.overrides)
            }
            catch
            {
                if loadError == nil { loadError = error }
                return nil
            }
        }
        let requestedURLs = Set(characters.compactMap { $0?.url })
        guard requestedURLs != Set(preparedModels.keys) else { return loadError }
        for url in preparedModels.keys where !requestedURLs.contains(url)
        {
            if let prepared = preparedModels.removeValue(forKey: url), case let .success(model) = prepared.renderable
            {
                captureSpace.remove(model.object)
            }
        }

        for case let character? in characters where preparedModels[character.url] == nil
        {
            let source = CharacterModelSource.source(for: character.url)
            let prepared = Result { try CharacterModelRenderable(context: context, model: source.load()) }
            preparedModels[character.url] = PreparedModel(source: source, renderable: prepared)
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
        let character = characters.indices.contains(index) ? characters[index] : nil
        let model = character.flatMap { try? preparedModels[$0.url]?.renderable.get() }
        if activeModel !== model
        {
            activeModel?.object.visible = false
            activeModel = model
            lastSelection = nil
        }
        if let character { model?.setOverrides(character.overrides) }
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
