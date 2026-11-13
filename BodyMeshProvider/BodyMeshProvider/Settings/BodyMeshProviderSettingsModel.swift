import BodyMeshProviderCore
import Foundation
import Observation

struct BodyMeshProviderRuntimeStatus: Equatable, Sendable
{
    enum Compatibility: Equatable, Sendable
    {
        case noAssetSelected
        case awaitingLoad
        case compatible
        case incompatible
    }

    let assetDisplayName: String
    let compatibility: Compatibility
    let nativeFrameRate: Float?
    let frameCount: Int?
    let duration: TimeInterval?
    let errorMessage: String?

    static let noAssetSelected = BodyMeshProviderRuntimeStatus(
        assetDisplayName: "No folder selected",
        compatibility: .noAssetSelected,
        nativeFrameRate: nil,
        frameCount: nil,
        duration: nil,
        errorMessage: nil
    )

    static func awaitingLoad(assetFolderURL: URL) -> BodyMeshProviderRuntimeStatus
    {
        BodyMeshProviderRuntimeStatus(
            assetDisplayName: assetFolderURL.lastPathComponent,
            compatibility: .awaitingLoad,
            nativeFrameRate: nil,
            frameCount: nil,
            duration: nil,
            errorMessage: nil
        )
    }

    static func compatible(
        assetDisplayName: String,
        archiveReader: CoMotionArchiveReader
    ) -> BodyMeshProviderRuntimeStatus
    {
        BodyMeshProviderRuntimeStatus(
            assetDisplayName: assetDisplayName,
            compatibility: .compatible,
            nativeFrameRate: archiveReader.metadata.encodedFrameRate,
            frameCount: archiveReader.frameCount,
            duration: archiveReader.duration,
            errorMessage: nil
        )
    }

    static func incompatible(
        assetFolderURL: URL,
        error: any Error
    ) -> BodyMeshProviderRuntimeStatus
    {
        incompatible(
            assetDisplayName: assetFolderURL.lastPathComponent,
            error: error
        )
    }

    static func incompatible(
        assetDisplayName: String,
        error: any Error
    ) -> BodyMeshProviderRuntimeStatus
    {
        BodyMeshProviderRuntimeStatus(
            assetDisplayName: assetDisplayName,
            compatibility: .incompatible,
            nativeFrameRate: nil,
            frameCount: nil,
            duration: nil,
            errorMessage: error.localizedDescription
        )
    }

    func reporting(error: any Error) -> BodyMeshProviderRuntimeStatus
    {
        BodyMeshProviderRuntimeStatus(
            assetDisplayName: assetDisplayName,
            compatibility: compatibility,
            nativeFrameRate: nativeFrameRate,
            frameCount: frameCount,
            duration: duration,
            errorMessage: error.localizedDescription
        )
    }

    func clearingError() -> BodyMeshProviderRuntimeStatus
    {
        BodyMeshProviderRuntimeStatus(
            assetDisplayName: assetDisplayName,
            compatibility: compatibility,
            nativeFrameRate: nativeFrameRate,
            frameCount: frameCount,
            duration: duration,
            errorMessage: nil
        )
    }
}

@MainActor @Observable
final class BodyMeshProviderSettingsModel
{
    private var settings: BodyMeshProviderSettings
    var isChoosingAssetFolder = false
    var importErrorMessage: String?
    private(set) var runtimeStatus: BodyMeshProviderRuntimeStatus

    @ObservationIgnored private let updateSettings: (BodyMeshProviderSettings) -> Void
    @ObservationIgnored private let reloadAsset: () -> Void

    init(
        settings: BodyMeshProviderSettings,
        runtimeStatus: BodyMeshProviderRuntimeStatus,
        updateSettings: @escaping (BodyMeshProviderSettings) -> Void,
        reloadAsset: @escaping () -> Void
    )
    {
        self.settings = settings
        self.runtimeStatus = runtimeStatus
        self.updateSettings = updateSettings
        self.reloadAsset = reloadAsset
    }

    var assetFolderDisplayName: String
    {
        guard let assetFolderURL = settings.assetFolderURL else { return "No folder selected" }
        return assetFolderURL.lastPathComponent
    }

    var compatibilityDescription: String
    {
        switch runtimeStatus.compatibility
        {
            case .noAssetSelected:
                return "No asset selected"
            case .awaitingLoad:
                return "Waiting to load"
            case .compatible:
                return "Compatible"
            case .incompatible:
                return "Incompatible"
        }
    }

    var nativeFrameRateDescription: String?
    {
        runtimeStatus.nativeFrameRate?.formatted(
            .number.precision(.fractionLength(0 ... 2))
        )
    }

    var frameCountDescription: String?
    {
        runtimeStatus.frameCount?.formatted(.number)
    }

    var durationDescription: String?
    {
        guard let duration = runtimeStatus.duration else { return nil }
        return duration.formatted(
            .number.precision(.fractionLength(0 ... 2))
        ) + " seconds"
    }

    var canReloadAsset: Bool
    {
        settings.assetFolderURL != nil
    }

    func selectAssetFolder(_ selectedURL: URL)
    {
        let standardizedURL = selectedURL.standardizedFileURL
        let folderURLString = standardizedURL.absoluteString
        importErrorMessage = nil
        if settings.assetFolderURLString == folderURLString
        {
            requestReload()
            return
        }

        settings.assetFolderURLString = folderURLString
        runtimeStatus = .awaitingLoad(assetFolderURL: standardizedURL)
        updateSettings(settings)
    }

    func clearAssetFolder()
    {
        settings.assetFolderURLString = ""
        importErrorMessage = nil
        runtimeStatus = .noAssetSelected
        updateSettings(settings)
    }

    func reportImportError(_ error: any Error)
    {
        importErrorMessage = error.localizedDescription
    }

    func requestReload()
    {
        guard let assetFolderURL = settings.assetFolderURL else { return }
        runtimeStatus = .awaitingLoad(assetFolderURL: assetFolderURL)
        reloadAsset()
    }

    func synchronize(
        settings: BodyMeshProviderSettings,
        runtimeStatus: BodyMeshProviderRuntimeStatus
    )
    {
        self.settings = settings
        self.runtimeStatus = runtimeStatus
    }
}
