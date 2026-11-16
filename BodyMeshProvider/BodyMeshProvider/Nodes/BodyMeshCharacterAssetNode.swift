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
        var storeAbsoluteModelPath: Bool?

        func savingModel(relativeTo directory: URL?) -> Self
        {
            var settings = self
            settings.characterModelURL = BodyMeshProviderResources.fileURLForSaving(
                characterModelURL,
                relativeTo: directory,
                storeAbsolutePath: storeAbsoluteModelPath == true
            )
            return settings
        }
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
        selection.withLock { $0 }.savingModel(relativeTo: graph?.fileReferenceBaseURL)
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
            let settings = selection.withLock { $0 }
            let modelURL = BodyMeshProviderResources.resolveFileURL(settings.characterModelURL, relativeTo: graph?.fileReferenceBaseURL)
            let section = CharacterModelSettingsSection(
                modelURL: modelURL,
                allowsBuiltIn: false,
                storesAbsolutePath: settings.storeAbsoluteModelPath == true,
                selectModel: { [weak self] url in self?.updateSettings { $0.characterModelURL = url } },
                setPathStorage: { [weak self] enabled in self?.updateSettings { $0.storeAbsoluteModelPath = enabled ? true : nil } }
            )
            return AnyView(Form {
                section
                Button("Add Character Inspector", systemImage: "slider.horizontal.3") { self.addInspector() }
                    .disabled(graph == nil)
            }.formStyle(.grouped))
        }
    }

    private func updateSettings(_ edit: (inout Settings) -> Void)
    {
        var settings = selection.withLock { $0 }
        edit(&settings)
        setSettings(settings.savingModel(relativeTo: graph?.fileReferenceBaseURL))
    }

    @MainActor private func addInspector()
    {
        guard let graph else { return }
        let output: NodePort<String> = port(named: "outputCharacter")
        let viewInputs = output.connectedInlets.filter { $0.node is BodyMeshSceneViewNode }
        let inspector = CharacterInspectorNode(context: context)
        inspector.offset = CGSize(width: offset.width + 45, height: offset.height - 185 - CGFloat(output.connectedInlets.count) * 75)

        let undo = graph.undoManager
        undo?.beginUndoGrouping()
        defer
        {
            undo?.endUndoGrouping()
            undo?.setActionName("Add Character Inspector")
        }
        graph.addNode(inspector)
        guard graph.connect(output, to: inspector.inputCharacter) != nil else { return }
        if viewInputs.count == 1, let inlet = viewInputs.first
        {
            graph.connect(inspector.outputCharacter, to: inlet)
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
