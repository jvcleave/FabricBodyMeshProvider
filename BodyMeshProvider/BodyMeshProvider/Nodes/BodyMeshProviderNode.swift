import BodyMeshProviderCore
import Fabric
import Foundation
import Metal
import Satin
import SwiftUI
import simd

private enum BodyMeshProviderNodeError: LocalizedError
{
    case invalidAssetFolderURL

    var errorDescription: String?
    {
        switch self
        {
            case .invalidAssetFolderURL:
                return "The Body Mesh Provider asset folder URL is invalid."
        }
    }
}

public final class BodyMeshProviderNode: BaseGeometryNode
{
    public override class var name: String { "Body Mesh Provider" }
    public override class var nodeDescription: String
    {
        "Loads a CMResearchKit body-mesh asset and provides its animated geometry."
    }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }

    public private(set) var providerSettings: BodyMeshProviderSettings

    private lazy var bodyMeshGeometry = BodyMeshGeometry(context: context)
    public override var geometry: Geometry { bodyMeshGeometry }

    private var archiveReader: CoMotionArchiveReader?
    private var attemptedAssetFolderURLString: String?
    private var assetLoadError: (any Error)?
    private var lastEvaluationKey: BodyMeshFrameSelection?
    private var hasPublishedGeometry = false
    private var runtimeStatus = BodyMeshProviderRuntimeStatus.noAssetSelected
    private weak var settingsModel: BodyMeshProviderSettingsModel?

    private enum CodingKeys: String, CodingKey
    {
        case providerSettings
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        BodyMeshPlaybackPorts.inputs() + super.registerPorts(context: context) + BodyMeshPlaybackPorts.outputs()
    }

    public var inputTime: ParameterPort<Float> { port(named: "inputTime") }
    public var inputLoop: ParameterPort<Bool> { port(named: "inputLoop") }
    public var inputPlaybackRate: ParameterPort<Float> { port(named: "inputPlaybackRate") }
    public var inputConfidence: ParameterPort<Float> { port(named: "inputConfidence") }
    public var inputMaximumBodies: ParameterPort<Int> { port(named: "inputMaximumBodies") }
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
        providerSettings = BodyMeshProviderSettings()
        super.init(context: context)
    }

    public init(context: Context, settings: BodyMeshProviderSettings)
    {
        providerSettings = settings
        super.init(context: context)
    }

    public required init(from decoder: any Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerSettings = try container.decodeIfPresent(
            BodyMeshProviderSettings.self,
            forKey: .providerSettings
        ) ?? BodyMeshProviderSettings()
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws
    {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerSettings, forKey: .providerSettings)
    }

    public func setProviderSettings(_ settings: BodyMeshProviderSettings)
    {
        guard providerSettings != settings else { return }
        providerSettings = settings
        reloadAsset()
    }

    public override func providesSettingsView() -> Bool { true }

    public override func settingsView() -> AnyView
    {
        // Fabric's override predates SwiftUI's actor annotation, but Fabric invokes
        // settings-view construction from its main-actor view hierarchy.
        MainActor.assumeIsolated
        {
            let model = settingsModel ?? BodyMeshProviderSettingsModel(
                settings: providerSettings,
                runtimeStatus: runtimeStatus,
                updateSettings:
                { [weak self] settings in
                    self?.setProviderSettings(settings)
                },
                reloadAsset:
                { [weak self] in
                    self?.reloadAsset()
                }
            )
            settingsModel = model
            return AnyView(BodyMeshProviderSettingsView(model: model))
        }
    }

    public override var settingsSize: SettingsViewSize
    {
        .Custom(size: CGSize(width: 460, height: 390))
    }

    public override func stopExecution(renderer: GraphRenderer) throws
    {
        invalidateLoadedAsset()
        bodyMeshGeometry.releaseResources()
        try super.stopExecution(renderer: renderer)
    }

    public override func execute(
        renderer: GraphRenderer,
        executionInfo: GraphExecutionInfo,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws
    {
        var shouldPublishGeometry = evaluate(
            geometry: geometry,
            atTime: executionInfo.timing.time
        )
        var requestedFrameIndex: Int?
        do
        {
            try loadAssetIfNeeded()

            guard let archiveReader else
            {
                if hasPublishedGeometry == false
                {
                    publishEmptyState()
                    hasPublishedGeometry = true
                    shouldPublishGeometry = true
                }
                if shouldPublishGeometry
                {
                    publishGeometry()
                }
                return
            }

            let evaluationKey = BodyMeshFrameSelection(node: self, graphTime: executionInfo.timing.time, archive: archiveReader)
            let frameIndex = evaluationKey.frameIndex
            requestedFrameIndex = frameIndex

            guard evaluationKey != lastEvaluationKey else
            {
                if shouldPublishGeometry
                {
                    publishGeometry()
                }
                return
            }

            let frame = try archiveReader.frameAtIndex(frameIndex)
            let people: [CoMotionFramePerson]
            switch frame.status
            {
                case let .available(framePeople):
                    people = framePeople
                case .failed:
                    people = []
            }

            let selectedPeople = evaluationKey.select(people)

            if selectedPeople.isEmpty
            {
                bodyMeshGeometry.clearMeshes()
            }
            else
            {
                let reconstructor = try BodyMeshProviderResources.meshReconstructor()
                try bodyMeshGeometry.replaceBodies(selectedPeople, reconstructor: reconstructor)
            }

            outputDetectedBodies.send(people.count)
            outputBodies.send(selectedPeople.count)
            outputCurrentFrame.send(frameIndex)
            outputFrameAvailable.send(selectedPeople.isEmpty == false)
            lastEvaluationKey = evaluationKey
            hasPublishedGeometry = true
            if runtimeStatus.errorMessage != nil
            {
                updateRuntimeStatus(runtimeStatus.clearingError())
            }

            publishGeometry()
        }
        catch
        {
            bodyMeshGeometry.clearMeshes()
            lastEvaluationKey = nil
            if archiveReader == nil
            {
                publishEmptyState()
                if let assetFolderURL = providerSettings.assetFolderURL
                {
                    updateRuntimeStatus(
                        .incompatible(
                            assetFolderURL: assetFolderURL,
                            error: error
                        )
                    )
                }
                else if providerSettings.assetFolderURLString.isEmpty == false
                {
                    updateRuntimeStatus(
                        .incompatible(
                            assetDisplayName: "Invalid asset folder",
                            error: error
                        )
                    )
                }
            }
            else
            {
                publishEmptyFrameState(frameIndex: requestedFrameIndex)
                updateRuntimeStatus(runtimeStatus.reporting(error: error))
            }
            hasPublishedGeometry = true
            publishGeometry()
            throw FabricError(
                .execution(.failed),
                severity: .recoverable,
                message: error.localizedDescription,
                underlyingError: error
            )
        }
    }

    private func loadAssetIfNeeded() throws
    {
        let selectedURLString = providerSettings.assetFolderURLString
        guard selectedURLString != attemptedAssetFolderURLString else
        {
            if let assetLoadError
            {
                throw assetLoadError
            }
            return
        }

        archiveReader = nil
        assetLoadError = nil
        lastEvaluationKey = nil
        hasPublishedGeometry = false
        attemptedAssetFolderURLString = selectedURLString

        guard selectedURLString.isEmpty == false else
        {
            publishEmptyState()
            updateRuntimeStatus(.noAssetSelected)
            return
        }
        guard let assetFolderURL = providerSettings.assetFolderURL else
        {
            assetLoadError = BodyMeshProviderNodeError.invalidAssetFolderURL
            throw BodyMeshProviderNodeError.invalidAssetFolderURL
        }

        updateRuntimeStatus(.awaitingLoad(assetFolderURL: assetFolderURL))
        do
        {
            let newArchiveReader = try CoMotionArchiveReader(directoryURL: assetFolderURL)
            let descriptor = try BodyMeshAssetDescriptor.loadIfPresent(
                directoryURL: assetFolderURL
            )
            try descriptor?.validate(archiveReader: newArchiveReader)

            archiveReader = newArchiveReader
            outputFrameRate.send(newArchiveReader.metadata.encodedFrameRate)
            outputFrameCount.send(newArchiveReader.frameCount)
            outputDuration.send(Float(newArchiveReader.duration))
            outputSourceSize.send(newArchiveReader.metadata.sourceSize)
            updateRuntimeStatus(
                .compatible(
                    assetDisplayName: descriptor?.name ?? assetFolderURL.lastPathComponent,
                    archiveReader: newArchiveReader
                )
            )
        }
        catch
        {
            assetLoadError = error
            throw error
        }
    }

    private func publishEmptyState()
    {
        bodyMeshGeometry.clearMeshes()
        outputDetectedBodies.send(0)
        outputBodies.send(0)
        outputCurrentFrame.send(0)
        outputFrameRate.send(0)
        outputFrameCount.send(0)
        outputDuration.send(0)
        outputFrameAvailable.send(false)
        outputSourceSize.send(.zero)
    }

    private func publishEmptyFrameState(frameIndex: Int?)
    {
        bodyMeshGeometry.clearMeshes()
        outputDetectedBodies.send(0)
        outputBodies.send(0)
        if let frameIndex
        {
            outputCurrentFrame.send(frameIndex)
        }
        outputFrameAvailable.send(false)
    }

    private func invalidateLoadedAsset()
    {
        archiveReader = nil
        attemptedAssetFolderURLString = nil
        assetLoadError = nil
        lastEvaluationKey = nil
        hasPublishedGeometry = false
    }

    private func reloadAsset()
    {
        invalidateLoadedAsset()
        let status = providerSettings.assetFolderURL.map(BodyMeshProviderRuntimeStatus.awaitingLoad)
            ?? .noAssetSelected
        updateRuntimeStatus(status)
        markDirty()
    }

    private func updateRuntimeStatus(_ newStatus: BodyMeshProviderRuntimeStatus)
    {
        runtimeStatus = newStatus
        guard let settingsModel else { return }
        let currentSettings = providerSettings
        Task { @MainActor [weak settingsModel] in
            settingsModel?.synchronize(
                settings: currentSettings,
                runtimeStatus: newStatus
            )
        }
    }

    private func publishGeometry()
    {
        outputGeometry.send(geometry, force: true)
    }

}
