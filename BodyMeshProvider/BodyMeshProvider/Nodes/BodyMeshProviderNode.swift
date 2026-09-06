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

public final class BodyMeshProviderNode: Node
{
    public override class var name: String { "Body Mesh Provider" }
    public override class var nodeType: Node.NodeType { .Geometery }
    public override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
    public override class var nodeDescription: String
    {
        "Loads a CMResearchKit body-mesh asset and provides its animated geometry."
    }
    public override class var nodeTimeMode: Node.TimeMode { .TimeBase }

    public private(set) var providerSettings: BodyMeshProviderSettings

    private lazy var bodyMeshGeometry = BodyMeshGeometry(context: context)
    private var archiveReader: CoMotionArchiveReader?
    private var attemptedAssetFolderURLString: String?
    private var assetLoadError: (any Error)?
    private var lastEvaluationKey: EvaluationKey?
    private var hasPublishedGeometry = false
    private var reconstructionWorkspace = CoMotionMeshReconstructionWorkspace()
    private var runtimeStatus = BodyMeshProviderRuntimeStatus.noAssetSelected
    private weak var settingsModel: BodyMeshProviderSettingsModel?

    private enum CodingKeys: String, CodingKey
    {
        case providerSettings
    }

    private struct EvaluationKey: Equatable
    {
        let frameIndex: Int
        let confidenceThreshold: Float
        let maximumBodyCount: Int
    }

    public override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)]
    {
        let providerInputs: [(name: String, port: Fabric.Port)] =
        [
            (
                "inputTime",
                ParameterPort(
                    parameter: FloatParameter(
                        "Time",
                        0,
                        .inputfield,
                        "Playback time in seconds; graph time is used when this inlet is unconnected"
                    )
                )
            ),
            (
                "inputLoop",
                ParameterPort(
                    parameter: BoolParameter(
                        "Loop",
                        true,
                        .toggle,
                        "Wrap playback at the end of the asset"
                    )
                )
            ),
            (
                "inputPlaybackRate",
                ParameterPort(
                    parameter: FloatParameter(
                        "Playback Rate",
                        1,
                        .inputfield,
                        "Graph-time playback multiplier; ignored when Time is connected"
                    )
                )
            ),
            (
                "inputConfidence",
                ParameterPort(
                    parameter: FloatParameter(
                        "Confidence",
                        0.2,
                        0.05,
                        1,
                        .slider,
                        "Minimum confidence required to output a detected body"
                    )
                )
            ),
            (
                "inputMaximumBodies",
                ParameterPort(
                    parameter: IntParameter(
                        "Maximum Bodies",
                        1,
                        1,
                        8,
                        .inputfield,
                        "Maximum number of highest-confidence bodies to merge into the geometry"
                    )
                )
            ),
        ]

        let geometryPorts: [(name: String, port: Fabric.Port)] =
        [
            (
                "inputPrimitiveType",
                ParameterPort(
                    parameter: StringParameter(
                        "Primitive",
                        "Triangle",
                        ["Point", "Line", "Line Strip", "Triangle", "Triangle Strip"],
                        .dropdown,
                        "Rendering primitive type for the geometry mesh"
                    )
                )
            ),
            (
                "outputGeometry",
                NodePort<Geometry>(
                    name: "Geometry",
                    kind: .Outlet,
                    description: "The reconstructed body mesh geometry"
                )
            ),
        ]

        let providerOutputs: [(name: String, port: Fabric.Port)] =
        [
            (
                "outputDetectedBodies",
                NodePort<Int>(
                    name: "Detected Bodies",
                    kind: .Outlet,
                    description: "Number of bodies stored in the current frame before filtering"
                )
            ),
            (
                "outputBodies",
                NodePort<Int>(
                    name: "Output Bodies",
                    kind: .Outlet,
                    description: "Number of bodies included in the geometry after filtering"
                )
            ),
            (
                "outputCurrentFrame",
                NodePort<Int>(
                    name: "Current Frame",
                    kind: .Outlet,
                    description: "Zero-based archive frame currently selected"
                )
            ),
            (
                "outputFrameRate",
                NodePort<Float>(
                    name: "Frame Rate",
                    kind: .Outlet,
                    description: "Encoded frame rate of the selected asset"
                )
            ),
            (
                "outputFrameCount",
                NodePort<Int>(
                    name: "Frame Count",
                    kind: .Outlet,
                    description: "Total number of archive frames"
                )
            ),
            (
                "outputDuration",
                NodePort<Float>(
                    name: "Duration",
                    kind: .Outlet,
                    description: "Asset playback duration in seconds"
                )
            ),
            (
                "outputFrameAvailable",
                NodePort<Bool>(
                    name: "Frame Available",
                    kind: .Outlet,
                    description: "True when at least one body passed filtering in the current frame"
                )
            ),
            (
                "outputSourceSize",
                NodePort<simd_float2>(
                    name: "Source Size",
                    kind: .Outlet,
                    description: "Encoded source width and height"
                )
            ),
        ]

        return providerInputs + geometryPorts + super.registerPorts(context: context) + providerOutputs
    }

    public var inputTime: ParameterPort<Float> { port(named: "inputTime") }
    public var inputLoop: ParameterPort<Bool> { port(named: "inputLoop") }
    public var inputPlaybackRate: ParameterPort<Float> { port(named: "inputPlaybackRate") }
    public var inputConfidence: ParameterPort<Float> { port(named: "inputConfidence") }
    public var inputMaximumBodies: ParameterPort<Int> { port(named: "inputMaximumBodies") }
    public var inputPrimitiveType: ParameterPort<String> { port(named: "inputPrimitiveType") }

    public var outputGeometry: NodePort<Geometry> { port(named: "outputGeometry") }
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
        invalidateLoadedAsset()
        if let assetFolderURL = settings.assetFolderURL
        {
            updateRuntimeStatus(.awaitingLoad(assetFolderURL: assetFolderURL))
        }
        else
        {
            updateRuntimeStatus(.noAssetSelected)
        }
        markDirty()
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
                updateAssetFolder:
                { [weak self] assetFolderURL in
                    self?.setProviderSettings(
                        BodyMeshProviderSettings(assetFolderURL: assetFolderURL)
                    )
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
        var requestedFrameIndex: Int?
        do
        {
            try loadAssetIfNeeded()

            guard let archiveReader else
            {
                var shouldPublishGeometry = inputPrimitiveType.valueDidChange
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

            let playbackTime: TimeInterval
            if inputTime.connectedOutlets.isEmpty
            {
                playbackTime = executionInfo.timing.time * TimeInterval(inputPlaybackRate.value ?? 1)
            }
            else
            {
                playbackTime = TimeInterval(inputTime.value ?? 0)
            }

            let frameIndex = archiveReader.frameIndex(
                time: playbackTime,
                loop: inputLoop.value ?? true
            )
            requestedFrameIndex = frameIndex
            let confidenceThreshold = min(max(inputConfidence.value ?? 0.2, 0.05), 1)
            let maximumBodyCount = min(max(inputMaximumBodies.value ?? 1, 1), 8)
            let evaluationKey = EvaluationKey(
                frameIndex: frameIndex,
                confidenceThreshold: confidenceThreshold,
                maximumBodyCount: maximumBodyCount
            )

            guard evaluationKey != lastEvaluationKey || inputPrimitiveType.valueDidChange else
            {
                return
            }

            if evaluationKey == lastEvaluationKey
            {
                publishGeometry()
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

            let selectedPeople = people.enumerated()
                .filter { $0.element.confidence > confidenceThreshold }
                .sorted
                { firstPerson, secondPerson in
                    if firstPerson.element.confidence == secondPerson.element.confidence
                    {
                        return firstPerson.offset < secondPerson.offset
                    }
                    return firstPerson.element.confidence > secondPerson.element.confidence
                }
                .prefix(maximumBodyCount)

            if selectedPeople.isEmpty
            {
                bodyMeshGeometry.clearMeshes()
            }
            else
            {
                let reconstructor = try BodyMeshProviderResources.meshReconstructor()
                try bodyMeshGeometry.replaceMeshes(
                    from: selectedPeople,
                    expectedBodyCount: selectedPeople.count
                )
                { indexedPerson in
                    try reconstructor.reconstructMesh(
                        parameters: indexedPerson.element.meshParameters,
                        workspace: &reconstructionWorkspace,
                        includeLocalVertices: false
                    )
                }
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
        if let assetFolderURL = providerSettings.assetFolderURL
        {
            updateRuntimeStatus(.awaitingLoad(assetFolderURL: assetFolderURL))
        }
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
        bodyMeshGeometry.primitiveType = selectedPrimitiveType()
        outputGeometry.send(bodyMeshGeometry, force: true)
    }

    private func selectedPrimitiveType() -> MTLPrimitiveType
    {
        switch inputPrimitiveType.value
        {
            case "Point":
                return .point
            case "Line":
                return .line
            case "Line Strip":
                return .lineStrip
            case "Triangle Strip":
                return .triangleStrip
            default:
                return .triangle
        }
    }
}
