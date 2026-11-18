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
    public override class var nodeDescription: String { "Animate the built-in body or a Creator USDZ with a CoMotion archive." }

    private struct SourceRequest: Sendable
    {
        var settings: CharacterModelSettings
        var modelRevision: UInt64 = 0
        var archiveRevision: UInt64 = 0
    }

    private struct ArchiveRequest: Equatable
    {
        let url: URL?
        let revision: UInt64
    }

    // Editor and graph execution share the source request. The graph owns the
    // loaded resources, frame selection, and all scene mutations.
    private let sourceRequest: OSAllocatedUnfairLock<SourceRequest>
    private var attemptedModelRevision: UInt64?
    private var attemptedArchive: ArchiveRequest?
    private lazy var sceneObject = Object(context: context, label: Self.name)
    private var importedCharacter: CharacterModelRenderable?
    private var builtInCharacter: BuiltInCharacterRenderable?
    private var archive: CoMotionArchiveReader?
    private var lastFrame: BodyMeshFrameSelection?
    private var didPrepareReferencePose = false

    public override var object: Object? { sceneObject }
    public override var settings: (any NodeSettings)?
    {
        // Export serializes the settings without copying the document directory.
        let directory = graph?.fileReferenceBaseURL
        return sourceRequest.withLock { $0.settings.resolvingArchive(relativeTo: directory) }
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
        return BodyMeshPlaybackPorts.inputs() + ports + BodyMeshPlaybackPorts.outputs()
    }

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
        let archiveURL = settings.resolvingArchive(relativeTo: directory).motionArchiveURL
        sourceRequest.withLock { request in
            if request.settings.characterModelURL != settings.characterModelURL { request.modelRevision &+= 1 }
            if request.settings.resolvingArchive(relativeTo: directory).motionArchiveURL != archiveURL
            {
                request.archiveRevision &+= 1
            }
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
                    let settings = self.sourceRequest.withLock { request in
                        if request.settings.characterModelURL == url { request.modelRevision &+= 1 }
                        return request.settings
                    }
                    self.setSettings(CharacterModelSettings(characterModelURL: url, motionArchiveURL: settings.motionArchiveURL))
                },
                selectArchive: { [weak self] url in
                    guard let self else { return }
                    let directory = self.graph?.fileReferenceBaseURL
                    let settings = self.sourceRequest.withLock { request in
                        if request.settings.resolvingArchive(relativeTo: directory).motionArchiveURL == url
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
        attemptedModelRevision = nil
        attemptedArchive = nil
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
        let directory = graph?.fileReferenceBaseURL
        let archiveRequest = ArchiveRequest(
            url: request.settings.resolvingArchive(relativeTo: directory).motionArchiveURL,
            revision: request.archiveRevision
        )
        var requestedFrameIndex: Int?
        var detectedBodies = 0
        do
        {
            try loadCharacterModel(request)
            try loadMotionArchive(archiveRequest)
            guard sourceRequest.withLock({ $0.modelRevision == request.modelRevision && $0.archiveRevision == request.archiveRevision })
            else
            {
                clearPose()
                return
            }

            if let archive
            {
                let frame = BodyMeshFrameSelection(node: self, graphTime: executionInfo.timing.time, archive: archive)
                requestedFrameIndex = frame.frameIndex
                if frame != lastFrame
                {
                    let outputCount: Int
                    if let importedCharacter
                    {
                        let people = try archive.rigPeople(at: frame.frameIndex)
                        let selected = frame.select(people, confidence: \.confidence)
                        detectedBodies = people.count
                        try importedCharacter.prepare(selected)
                        outputCount = selected.count
                    }
                    else
                    {
                        let recorded = try archive.frameAtIndex(frame.frameIndex)
                        let people: [CoMotionFramePerson]
                        if case let .available(detections) = recorded.status { people = detections }
                        else { people = [] }
                        let selected = frame.select(people, confidence: \.confidence)
                        detectedBodies = people.count
                        try builtInCharacter?.prepare(selected)
                        outputCount = builtInCharacter == nil ? 0 : selected.count
                    }
                    publishFrame(index: frame.frameIndex, detected: detectedBodies, output: outputCount)
                    lastFrame = frame
                }
                else
                {
                    detectedBodies = outputDetectedBodies.value ?? 0
                }
            }
            else if request.settings.motionArchiveURL == nil, let importedCharacter
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

    private func clearPose()
    {
        lastFrame = nil
        didPrepareReferencePose = false
        importedCharacter?.clear()
        builtInCharacter?.clear()
    }

    private func loadCharacterModel(_ request: SourceRequest) throws
    {
        guard attemptedModelRevision != request.modelRevision else { return }
        attemptedModelRevision = request.modelRevision
        sceneObject.removeAll()
        importedCharacter = nil
        builtInCharacter = nil
        lastFrame = nil
        didPrepareReferencePose = false
        if let url = request.settings.characterModelURL
        {
            let model = try waitForSource { try await CharacterModelImport.load(url) }
            let prepared = try CharacterModelRenderable(context: context, model: model)
            guard sourceRequest.withLock({ $0.modelRevision == request.modelRevision }) else { return }
            sceneObject.add(prepared.object)
            importedCharacter = prepared
        }
        else
        {
            let reconstructor = try waitForSource { try BodyMeshProviderResources.meshReconstructor() }
            let prepared = BuiltInCharacterRenderable(context: context, reconstructor: reconstructor)
            guard sourceRequest.withLock({ $0.modelRevision == request.modelRevision }) else { return }
            sceneObject.add(prepared.object)
            builtInCharacter = prepared
        }
    }

    private func loadMotionArchive(_ request: ArchiveRequest) throws
    {
        guard attemptedArchive != request else { return }
        attemptedArchive = request
        archive = nil
        clearPose()
        outputFrameRate.send(nil)
        outputFrameCount.send(nil)
        outputDuration.send(nil)
        outputSourceSize.send(nil)
        guard let url = request.url, url.scheme != nil else { return }
        guard url.isFileURL else { throw CharacterModelError.resources("The motion archive requires a local file URL.") }

        let archive = try waitForSource {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let resource = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if resource.isRegularFile == true
            {
                guard let size = resource.fileSize, size <= CoMotionArchiveFormat.maximumArchiveByteCount
                else { throw CoMotionArchiveReaderError.exceedsSizeLimit }
                return try CoMotionArchiveReader(data: Data(contentsOf: url, options: .mappedIfSafe))
            }
            let archive = try CoMotionArchiveReader(directoryURL: url)
            let descriptor = try BodyMeshAssetDescriptor.loadIfPresent(directoryURL: url)
            try descriptor?.validate(archiveReader: archive)
            return archive
        }
        guard sourceRequest.withLock({ $0.archiveRevision == request.revision }) else { return }
        self.archive = archive
        outputFrameRate.send(archive.metadata.encodedFrameRate)
        outputFrameCount.send(archive.frameCount)
        outputDuration.send(Float(archive.duration))
        outputSourceSize.send(archive.metadata.sourceSize)
    }

    private func waitForSource<Value: Sendable>(_ load: @escaping @Sendable () async throws -> Value) throws -> Value
    {
        let completed = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<Value, any Error>?>(initialState: nil)
        // Fabric draws immediately after cold graph startup. Only a changed
        // source waits for preparation. The worker never calls back into Fabric.
        Task.detached(priority: .userInitiated) {
            defer { completed.signal() }
            do
            {
                let value = try await load()
                result.withLock { $0 = .success(value) }
            }
            catch { result.withLock { $0 = .failure(error) } }
        }
        completed.wait()
        guard let loaded = result.withLock({ $0 })
        else { throw CharacterModelError.resources("The source worker did not return a result.") }
        return try loaded.get()
    }
}
