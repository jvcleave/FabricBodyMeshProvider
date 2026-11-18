import BodyMeshProviderCore
import Fabric
import Foundation
import Metal
import Satin
import SwiftUI
import os

public final class CoMotionDataNode: Node
{
    public override class var name: String { "CoMotion Data" }
    public override class var nodeType: Node.NodeType { .Utility }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }
    public override class var nodeDescription: String { "Play a CoMotion archive as shared motion frames." }

    private struct SourceRequest: Equatable, Sendable
    {
        var settings: CoMotionDataSettings
        var revision: UInt64 = 0
    }

    // The editor updates the request. The graph owns the loaded archive and frame.
    private let sourceRequest: OSAllocatedUnfairLock<SourceRequest>
    private var attemptedSource: SourceRequest?
    private var archive: CoMotionArchiveReader?
    private var lastFrameIndex: Int?

    private var outputCoMotionFrame: NodePort<CoMotionFramePayload.Values> { port(named: "outputCoMotionFrame") }
    private var outputSourceSize: NodePort<SIMD2<Float>> { port(named: "outputSourceSize") }

    public override var settings: (any NodeSettings)?
    {
        sourceRequest.withLock { $0.settings }.savingArchive(relativeTo: graph?.fileReferenceBaseURL)
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + BodyMeshPlaybackPorts.timingInputs() + [
            (
                "outputCoMotionFrame",
                NodePort<CoMotionFramePayload.Values>(
                    name: "CoMotion Frame",
                    kind: .Outlet,
                    description: "Detections and pose parameters for the selected frame"
                )
            ),
            (
                "outputSourceSize",
                NodePort<SIMD2<Float>>(
                    name: "Source Size",
                    kind: .Outlet,
                    description: "Encoded source width and height"
                )
            ),
        ]
    }

    public required init(context: Context)
    {
        sourceRequest = OSAllocatedUnfairLock(initialState: SourceRequest(settings: .init()))
        super.init(context: context)
    }

    public required init(from decoder: Decoder) throws
    {
        let settings = try CoMotionDataSettings(from: decoder)
        sourceRequest = OSAllocatedUnfairLock(initialState: SourceRequest(settings: settings))
        try super.init(from: decoder)
    }

    public override func apply(_ settings: any NodeSettings)
    {
        guard let settings = settings as? CoMotionDataSettings else { return }
        let directory = graph?.fileReferenceBaseURL
        let archiveURL = settings.resolvingArchive(relativeTo: directory).motionArchiveURL
        sourceRequest.withLock { request in
            if request.settings.resolvingArchive(relativeTo: directory).motionArchiveURL != archiveURL
            {
                request.revision &+= 1
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
            let section = MotionArchiveSettingsSection(
                archiveURL: settings.resolvingArchive(relativeTo: graph?.fileReferenceBaseURL).motionArchiveURL,
                storesAbsolutePath: settings.storeAbsoluteArchivePath == true,
                selectArchive: { [weak self] url in
                    guard let self else { return }
                    let directory = self.graph?.fileReferenceBaseURL
                    var settings = self.sourceRequest.withLock { request in
                        if request.settings.resolvingArchive(relativeTo: directory).motionArchiveURL == url
                        {
                            request.revision &+= 1
                        }
                        return request.settings
                    }
                    settings.motionArchiveURL = url
                    self.setSettings(settings.savingArchive(relativeTo: directory))
                },
                setPathStorage: { [weak self] enabled in
                    guard let self else { return }
                    var settings = self.sourceRequest.withLock { $0.settings }
                    settings.storeAbsoluteArchivePath = enabled ? true : nil
                    self.setSettings(settings.savingArchive(relativeTo: self.graph?.fileReferenceBaseURL))
                }
            )
            return AnyView(Form { section }.formStyle(.grouped))
        }
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        attemptedSource = nil
        clearArchive()
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let selection = sourceRequest.withLock { $0 }
        let request = SourceRequest(
            settings: selection.settings.resolvingArchive(relativeTo: graph?.fileReferenceBaseURL),
            revision: selection.revision
        )
        do
        {
            if attemptedSource != request
            {
                attemptedSource = request
                clearArchive()
                if let url = request.settings.motionArchiveURL
                {
                    let loadedArchive = try BodyMeshProviderResources.motionArchive(url)
                    guard sourceRequest.withLock({ $0.revision == request.revision }) else { return }
                    archive = loadedArchive
                    outputSourceSize.send(loadedArchive.metadata.sourceSize)
                }
            }

            guard let archive else { return }
            let index = BodyMeshFrameSelection.resolveFrameIndex(node: self, graphTime: executionInfo.timing.time, archive: archive)
            guard lastFrameIndex != index else { return }
            lastFrameIndex = index
            let frame = try CoMotionFramePayload(frameIndex: index, archive: archive)
            guard sourceRequest.withLock({ $0.revision == request.revision }) else { return }
            outputCoMotionFrame.send(frame.values)
        }
        catch
        {
            outputCoMotionFrame.send(nil)
            guard sourceRequest.withLock({ $0.revision == request.revision }) else { return }
            throw FabricError(.execution(.failed), severity: .recoverable, message: error.localizedDescription, underlyingError: error)
        }
    }

    private func clearArchive()
    {
        archive = nil
        lastFrameIndex = nil
        outputCoMotionFrame.send(nil)
        outputSourceSize.send(nil)
    }
}
