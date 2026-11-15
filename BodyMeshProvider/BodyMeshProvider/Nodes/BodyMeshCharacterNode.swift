import BodyMeshProviderCore
import Fabric
import Foundation
import Metal
import Satin
import SwiftUI
import os
import simd

public final class BodyMeshCharacterNode: ObjectNode<Object>
{
    public override class var name: String { "Body Mesh Character" }
    public override class var nodeType: Node.NodeType { .Object(objectType: .Loader) }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }
    public override class var nodeDescription: String { "Animate the built-in body or a Creator USDZ with CoMotion." }

    private struct SourceRequest: Sendable
    {
        var settings: CharacterModelSettings
        var modelRevision: UInt64 = 0
        var archiveRevision: UInt64 = 0
    }

    private struct FileRequest: Equatable
    {
        let url: URL?
        let revision: UInt64
    }

    // Editor and graph execution share the source request. The graph owns the
    // loaded resources, frame selection, and all scene mutations.
    private let sourceRequest: OSAllocatedUnfairLock<SourceRequest>
    private var attemptedModel: FileRequest?
    private var attemptedArchive: FileRequest?
    private lazy var sceneObject = Object(context: context, label: Self.name)
    private var importedCharacter: CharacterModelRenderable?
    private var builtInCharacter: BuiltInCharacterRenderable?
    private var archive: CoMotionArchiveReader?
    private var usesSharedMotion = false
    private var didReadSharedFrame = false
    private var sharedFrame: CoMotionFramePayload?
    private var lastFrame: BodyMeshFrameSelection?
    private var didPrepareReferencePose = false

    public override var object: Object? { sceneObject }
    public override var settings: (any NodeSettings)?
    {
        // Export serializes the settings without copying the document directory.
        let directory = graph?.fileReferenceBaseURL
        return sourceRequest.withLock { $0.settings.resolvingSources(relativeTo: directory) }
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        let ports = super.registerPorts(context: context)
        for (name, port) in ports where name == "inputOrientation"
        {
            if let orientation = port.parameter as? Float4Parameter
            {
                orientation.value = SIMD4(0, 0, 0, 1)
            }
        }
        return BodyMeshPlaybackPorts.inputs() + ports + BodyMeshPlaybackPorts.outputs() + [
            (
                "inputCoMotionFrame",
                NodePort<CoMotionFramePayload.Values>(
                    name: "CoMotion Frame",
                    kind: .Inlet,
                    description: "Shared motion frame from CoMotion Data"
                )
            ),
        ]
    }

    private var inputCoMotionFrame: NodePort<CoMotionFramePayload.Values> { port(named: "inputCoMotionFrame") }

    public var outputDetectedBodies: NodePort<Int> { port(named: "outputDetectedBodies") }
    public var outputBodies: NodePort<Int> { port(named: "outputBodies") }
    public var outputCurrentFrame: NodePort<Int> { port(named: "outputCurrentFrame") }
    public var outputFrameRate: NodePort<Float> { port(named: "outputFrameRate") }
    public var outputFrameCount: NodePort<Int> { port(named: "outputFrameCount") }
    public var outputDuration: NodePort<Float> { port(named: "outputDuration") }
    public var outputFrameAvailable: NodePort<Bool> { port(named: "outputFrameAvailable") }
    public var outputSourceSize: NodePort<simd_float2> { port(named: "outputSourceSize") }

    public required init(context: Context)
    {
        sourceRequest = OSAllocatedUnfairLock(initialState: SourceRequest(settings: .init()))
        super.init(context: context)
    }

    public required init(from decoder: Decoder) throws
    {
        let settings = try CharacterModelSettings(from: decoder)
        sourceRequest = OSAllocatedUnfairLock(initialState: SourceRequest(settings: settings))
        try super.init(from: decoder)
    }

    public override func apply(_ settings: any NodeSettings)
    {
        guard let settings = settings as? CharacterModelSettings else { return }
        let directory = graph?.fileReferenceBaseURL
        let resolved = settings.resolvingSources(relativeTo: directory)
        sourceRequest.withLock { request in
            let previous = request.settings.resolvingSources(relativeTo: directory)
            if previous.characterModelURL != resolved.characterModelURL { request.modelRevision &+= 1 }
            if previous.motionArchiveURL != resolved.motionArchiveURL { request.archiveRevision &+= 1 }
            request.settings = settings
        }
    }

    public override func providesSettingsView() -> Bool { true }
    public override var settingsSize: SettingsViewSize { .Medium }

    public override func settingsView() -> AnyView
    {
        performOnMainSync
        {
            let settings = sourceRequest.withLock { $0.settings }
            return AnyView(CharacterModelSettingsView(
                modelURL: settings.characterModelURL,
                archiveURL: settings.motionArchiveURL,
                selectModel: { [weak self] url in
                    guard let self else { return }
                    let directory = self.graph?.fileReferenceBaseURL
                    let settings = self.sourceRequest.withLock { request in
                        if request.settings.resolvingSources(relativeTo: directory).characterModelURL == url
                        {
                            request.modelRevision &+= 1
                        }
                        return request.settings
                    }
                    self.setSettings(CharacterModelSettings(characterModelURL: url, motionArchiveURL: settings.motionArchiveURL))
                },
                selectArchive: { [weak self] url in
                    guard let self else { return }
                    let directory = self.graph?.fileReferenceBaseURL
                    let settings = self.sourceRequest.withLock { request in
                        if request.settings.resolvingSources(relativeTo: directory).motionArchiveURL == url
                        {
                            request.archiveRevision &+= 1
                        }
                        return request.settings
                    }
                    self.setSettings(CharacterModelSettings(characterModelURL: settings.characterModelURL, motionArchiveURL: url))
                }
            ))
        }
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        attemptedModel = nil
        attemptedArchive = nil
        usesSharedMotion = false
        didReadSharedFrame = false
        sharedFrame = nil
        lastFrame = nil
        didPrepareReferencePose = false
        sceneObject.removeAll()
        importedCharacter = nil
        builtInCharacter = nil
        archive = nil
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        _ = evaluate(object: sceneObject, atTime: executionInfo.timing.time)
        let request = sourceRequest.withLock { $0 }
        let settings = request.settings.resolvingSources(relativeTo: graph?.fileReferenceBaseURL)
        // A published inlet can receive a value from an enclosing Sub Graph.
        let usesSharedInput = inputCoMotionFrame.published || !inputCoMotionFrame.connectedOutlets.isEmpty
        if usesSharedMotion != usesSharedInput
        {
            usesSharedMotion = usesSharedInput
            attemptedArchive = nil
            archive = nil
            didReadSharedFrame = false
            sharedFrame = nil
            clearPose()
            publishMotionMetadata()
        }
        var requestedFrameIndex: Int?
        var detectedBodies = 0
        do
        {
            try loadCharacterModel(FileRequest(url: settings.characterModelURL, revision: request.modelRevision))
            if usesSharedMotion
            {
                try updateSharedFrame()
            }
            else
            {
                try loadMotionArchive(FileRequest(url: settings.motionArchiveURL, revision: request.archiveRevision))
            }
            guard sourceRequest.withLock({ $0.modelRevision == request.modelRevision && $0.archiveRevision == request.archiveRevision })
            else
            {
                clearPose()
                return
            }

            let selection = sharedFrame.map { BodyMeshFrameSelection(node: self, frameIndex: $0.frameIndex) }
                ?? archive.map { BodyMeshFrameSelection(node: self, graphTime: executionInfo.timing.time, archive: $0) }
            if let selection
            {
                requestedFrameIndex = selection.frameIndex
                if selection != lastFrame
                {
                    let people: [CoMotionFramePerson]
                    if let sharedFrame { people = sharedFrame.people }
                    else if let archive, case let .available(detections) = try archive.frameAtIndex(selection.frameIndex).status
                    {
                        people = detections
                    }
                    else { people = [] }
                    let selected = selection.select(people)
                    detectedBodies = people.count
                    try importedCharacter?.prepare(selected)
                    try builtInCharacter?.prepare(selected)
                    let hasCharacter = importedCharacter != nil || builtInCharacter != nil
                    publishFrame(index: selection.frameIndex, detected: detectedBodies, output: hasCharacter ? selected.count : 0)
                    lastFrame = selection
                }
                else
                {
                    detectedBodies = outputDetectedBodies.value ?? 0
                }
            }
            else if !usesSharedMotion, settings.motionArchiveURL == nil, let importedCharacter
            {
                if !didPrepareReferencePose
                {
                    importedCharacter.prepareReferencePose()
                    publishFrame(index: nil, detected: 0, output: 0)
                    didPrepareReferencePose = true
                }
            }
            else
            {
                publishFrame(index: nil, detected: 0, output: 0)
            }

            try importedCharacter?.encode(commandBuffer: commandBuffer)
        }
        catch
        {
            clearPose()
            if usesSharedMotion, sharedFrame == nil { publishMotionMetadata() }
            publishFrame(index: requestedFrameIndex, detected: detectedBodies, output: 0)
            guard sourceRequest.withLock({ $0.modelRevision == request.modelRevision && $0.archiveRevision == request.archiveRevision }) else { return }
            throw FabricError(
                .execution(.failed),
                severity: .recoverable,
                message: error.localizedDescription,
                underlyingError: error
            )
        }
    }

    private func publishFrame(index: Int?, detected: Int, output: Int)
    {
        outputCurrentFrame.send(index)
        outputDetectedBodies.send(detected)
        outputBodies.send(output)
        outputFrameAvailable.send(output != 0)
    }

    private func publishMotionMetadata(frameRate: Float? = nil, frameCount: Int? = nil, sourceSize: SIMD2<Float>? = nil)
    {
        let duration: Float? = if let frameRate, let frameCount { Float(Double(frameCount) / Double(frameRate)) }
        else { nil }
        outputFrameRate.send(frameRate)
        outputFrameCount.send(frameCount)
        outputDuration.send(duration)
        outputSourceSize.send(sourceSize)
    }

    private func clearPose()
    {
        lastFrame = nil
        didPrepareReferencePose = false
        importedCharacter?.clear()
        builtInCharacter?.clear()
    }

    private func updateSharedFrame() throws
    {
        guard !didReadSharedFrame || inputCoMotionFrame.valueDidChange else { return }
        didReadSharedFrame = true
        lastFrame = nil
        sharedFrame = nil
        guard let values = inputCoMotionFrame.value, !values.isEmpty else
        {
            clearPose()
            publishMotionMetadata()
            return
        }
        let frame = try CoMotionFramePayload(values: values)
        sharedFrame = frame
        publishMotionMetadata(frameRate: frame.frameRate, frameCount: frame.frameCount, sourceSize: frame.sourceSize)
    }

    private func loadCharacterModel(_ request: FileRequest) throws
    {
        guard attemptedModel != request else { return }
        attemptedModel = request
        sceneObject.removeAll()
        importedCharacter = nil
        builtInCharacter = nil
        lastFrame = nil
        didPrepareReferencePose = false
        if let url = request.url
        {
            let model = try BodyMeshProviderResources.waitForSource { try await CharacterModelImport.load(url) }
            let prepared = try CharacterModelRenderable(context: context, model: model)
            guard sourceRequest.withLock({ $0.modelRevision == request.revision }) else { return }
            sceneObject.add(prepared.object)
            importedCharacter = prepared
        }
        else
        {
            let reconstructor = try BodyMeshProviderResources.waitForSource { try BodyMeshProviderResources.meshReconstructor() }
            let prepared = BuiltInCharacterRenderable(context: context, reconstructor: reconstructor)
            guard sourceRequest.withLock({ $0.modelRevision == request.revision }) else { return }
            sceneObject.add(prepared.object)
            builtInCharacter = prepared
        }
    }

    private func loadMotionArchive(_ request: FileRequest) throws
    {
        guard attemptedArchive != request else { return }
        attemptedArchive = request
        archive = nil
        clearPose()
        publishMotionMetadata()
        guard let url = request.url, url.scheme != nil else { return }
        let archive = try BodyMeshProviderResources.motionArchive(url)
        guard sourceRequest.withLock({ $0.archiveRevision == request.revision }) else { return }
        self.archive = archive
        publishMotionMetadata(frameRate: archive.metadata.encodedFrameRate, frameCount: archive.frameCount, sourceSize: archive.metadata.sourceSize)
    }
}
