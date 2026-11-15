import Fabric
import Foundation
import Metal
import Satin
import SwiftUI
import os

public final class BodyMeshCharacterAssetNode: Node
{
    public override class var name: String { "Body Mesh Character Asset" }
    public override class var nodeType: Node.NodeType { .Object(objectType: .Loader) }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeDescription: String { "Provides a mapped Creator USDZ for Body Mesh View." }

    private struct Settings: NodeSettings
    {
        var characterModelURL: URL?
    }

    private struct FileReference: Equatable
    {
        let url: URL?
        let directory: URL?
    }

    private let selection: OSAllocatedUnfairLock<Settings>
    private var publishedReference: FileReference?

    public override var settings: (any NodeSettings)?
    {
        let directory = graph?.fileReferenceBaseURL
        return selection.withLock {
            Settings(characterModelURL: BodyMeshProviderResources.resolveFileURL($0.characterModelURL, relativeTo: directory))
        }
    }

    public required init(context: Context)
    {
        selection = OSAllocatedUnfairLock(initialState: Settings())
        super.init(context: context)
    }

    public required init(from decoder: Decoder) throws
    {
        selection = OSAllocatedUnfairLock(initialState: try Settings(from: decoder))
        try super.init(from: decoder)
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + [
            (
                "outputCharacter",
                NodePort<String>(name: "Character", kind: .Outlet, description: "File reference to a mapped Creator USDZ")
            ),
        ]
    }

    public override func apply(_ settings: any NodeSettings)
    {
        guard let settings = settings as? Settings else { return }
        selection.withLock { $0 = settings }
    }

    public override func providesSettingsView() -> Bool { true }
    public override var settingsSize: SettingsViewSize { .Medium }

    public override func settingsView() -> AnyView
    {
        performOnMainSync
        {
            let modelURL = selection.withLock { $0.characterModelURL }
            let section = CharacterModelSettingsSection(modelURL: modelURL, allowsBuiltIn: false) { [weak self] url in
                self?.setSettings(Settings(characterModelURL: url))
            }
            return AnyView(Form { section }.formStyle(.grouped))
        }
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        publishedReference = nil
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let reference = FileReference(url: selection.withLock { $0.characterModelURL }, directory: graph?.fileReferenceBaseURL)
        guard publishedReference != reference else { return }
        publishedReference = reference
        let output: NodePort<String> = port(named: "outputCharacter")
        output.send(BodyMeshProviderResources.resolveFileURL(reference.url, relativeTo: reference.directory)?.absoluteString)
    }
}
