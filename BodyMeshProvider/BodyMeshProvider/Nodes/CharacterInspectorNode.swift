import Fabric
import Foundation
import Metal
import Satin
import SwiftUI
import os

public final class CharacterInspectorNode: Node
{
    public override class var name: String { "Character Inspector" }
    public override class var nodeType: Node.NodeType { .Utility }
    // Inspect a connected source while authoring a branch with no view yet.
    public override class var nodeExecutionMode: Node.ExecutionMode { .Consumer }
    public override class var nodeDescription: String { "Expose visibility and material inputs for a mapped USDZ character." }

    private struct Control
    {
        let target: CharacterInspectorSettings.Target
        let port: Fabric.Port
    }

    private struct Configuration
    {
        var settings = CharacterInspectorSettings(targets: [])
        var controls: [Control] = []
    }

    private let configurationLock = NSLock()
    private var configuration = Configuration()
    private let source = OSAllocatedUnfairLock(initialState: Optional<CharacterModelSource>.none)
    private var sourceDirectory: URL?
    private var didReadInput = false
    @MainActor private weak var settingsModel: CharacterInspectorSettingsModel?

    public var inputCharacter: NodePort<PortValue> { port(named: "inputCharacter") }
    public var outputCharacter: NodePort<PortValue> { port(named: "outputCharacter") }

    public override var settings: (any NodeSettings)? { configurationLock.withLock { configuration.settings } }

    public required init(context: Context)
    {
        super.init(context: context)
    }

    public init(context: Context, settings: CharacterInspectorSettings)
    {
        super.init(context: context)
        reconcilePorts(settings)
    }

    public required init(from decoder: Decoder) throws
    {
        let settings = try CharacterInspectorSettings(from: decoder)
        try super.init(from: decoder)
        reconcilePorts(settings)
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        super.registerPorts(context: context) + [
            ("inputCharacter", NodePort<PortValue>(name: "Character", kind: .Inlet, description: "Character asset or inspector output")),
            ("outputCharacter", NodePort<PortValue>(name: "Character", kind: .Outlet, description: "Character with its visibility and material overrides")),
        ]
    }

    public override func apply(_ settings: any NodeSettings)
    {
        guard let settings = settings as? CharacterInspectorSettings else { return }
        reconcilePorts(settings)
        refreshSettingsView()
        super.apply(settings)
    }

    /// Preserve surviving ports, including their wires and parameter values.
    /// Runtime takes a snapshot after the graph editor has applied the layout.
    private func reconcilePorts(_ settings: CharacterInspectorSettings)
    {
        let previous = configurationLock.withLock { configuration.controls }
        let retained = Dictionary(uniqueKeysWithValues: previous.map { ($0.target.id, $0.port) })
        let targetIDs = Set(settings.targets.map(\.id))
        for control in previous where !targetIDs.contains(control.target.id) { removePort(control.port) }

        let controls = settings.targets.map { target in
            if let port = retained[target.id] { return Control(target: target, port: port) }

            let port: Fabric.Port
            switch target.kind
            {
                case .meshVisibility, .materialVisibility:
                    port = ParameterPort(parameter: BoolParameter(target.portName, true, .button, target.path))
                case .material:
                    port = NodePort<Satin.Material>(name: target.portName, kind: .Inlet, description: target.path)
            }
            addDynamicPort(port, name: target.id)
            return Control(target: target, port: port)
        }
        reorderPorts([inputCharacter] + controls.map(\.port) + [outputCharacter])
        configurationLock.withLock { configuration = Configuration(settings: settings, controls: controls) }
        markDirty()
    }

    public override func providesSettingsView() -> Bool { true }
    public override var settingsSize: SettingsViewSize { .Large }

    public override func settingsView() -> AnyView
    {
        performOnMainSync {
            let model = settingsModel ?? CharacterInspectorSettingsModel { [weak self] settings in self?.setSettings(settings) }
            settingsModel = model
            synchronize(model)
            return AnyView(CharacterInspectorSettingsView(model: model))
        }
    }

    @MainActor private func synchronize(_ model: CharacterInspectorSettingsModel)
    {
        let settings = configurationLock.withLock { configuration.settings }
        model.synchronize(settings: settings, source: source.withLock { $0 })
    }

    private func refreshSettingsView()
    {
        performOnMainAsync { [weak self] in
            guard let self, let model = settingsModel else { return }
            synchronize(model)
        }
    }

    private func updateSource(_ url: URL?)
    {
        guard source.withLock({ $0?.url }) != url else { return }
        let next = url.map { CharacterModelSource.source(for: $0) }
        source.withLock { $0 = next }
        refreshSettingsView()
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        didReadInput = false
        sourceDirectory = nil
        updateSource(nil)
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        let directory = graph?.fileReferenceBaseURL
        guard !didReadInput || isDirty || sourceDirectory != directory else { return }
        didReadInput = true
        sourceDirectory = directory

        do
        {
            guard var reference = try CharacterReference(value: inputCharacter.value) else
            {
                updateSource(nil)
                outputCharacter.send(nil)
                return
            }
            updateSource(try reference.fileURL(relativeTo: directory))
            let controls = configurationLock.withLock { configuration.controls }
            for control in controls
            {
                let path = control.target.path
                switch control.target.kind
                {
                    case .meshVisibility:
                        if let visible = (control.port as? NodePort<Bool>)?.value { reference.overrides.meshVisibility[path] = visible }
                    case .materialVisibility:
                        if let visible = (control.port as? NodePort<Bool>)?.value { reference.overrides.materialVisibility[path] = visible }
                    case .material:
                        if let material = (control.port as? NodePort<Satin.Material>)?.value { reference.overrides.materials[path] = material }
                }
            }
            outputCharacter.send(reference.portValue)
        }
        catch
        {
            updateSource(nil)
            outputCharacter.send(nil)
            throw FabricError(.execution(.failed), severity: .recoverable, message: error.localizedDescription, underlyingError: error)
        }
    }
}
