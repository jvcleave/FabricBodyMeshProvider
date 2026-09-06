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
    var assetFolderURLString: String
    var isChoosingAssetFolder = false
    var importErrorMessage: String?
    private(set) var runtimeStatus: BodyMeshProviderRuntimeStatus

    @ObservationIgnored private let updateAssetFolder: (URL?) -> Void
    @ObservationIgnored private let reloadAsset: () -> Void

    init(
        settings: BodyMeshProviderSettings,
        runtimeStatus: BodyMeshProviderRuntimeStatus,
        updateAssetFolder: @escaping (URL?) -> Void,
        reloadAsset: @escaping () -> Void
    )
    {
        assetFolderURLString = settings.assetFolderURLString
        self.runtimeStatus = runtimeStatus
        self.updateAssetFolder = updateAssetFolder
        self.reloadAsset = reloadAsset
    }

    var assetFolderDisplayName: String
    {
        guard let assetFolderURL else { return "No folder selected" }
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
        assetFolderURL != nil
    }

    func selectAssetFolder(_ selectedURL: URL)
    {
        let standardizedURL = selectedURL.standardizedFileURL
        assetFolderURLString = standardizedURL.absoluteString
        importErrorMessage = nil
        runtimeStatus = .awaitingLoad(assetFolderURL: standardizedURL)
        updateAssetFolder(standardizedURL)
    }

    func clearAssetFolder()
    {
        assetFolderURLString = ""
        importErrorMessage = nil
        runtimeStatus = .noAssetSelected
        updateAssetFolder(nil)
    }

    func reportImportError(_ error: any Error)
    {
        importErrorMessage = error.localizedDescription
    }

    func requestReload()
    {
        guard let assetFolderURL else { return }
        runtimeStatus = .awaitingLoad(assetFolderURL: assetFolderURL)
        reloadAsset()
    }

    func synchronize(
        settings: BodyMeshProviderSettings,
        runtimeStatus: BodyMeshProviderRuntimeStatus
    )
    {
        assetFolderURLString = settings.assetFolderURLString
        self.runtimeStatus = runtimeStatus
    }

    private var assetFolderURL: URL?
    {
        guard assetFolderURLString.isEmpty == false else { return nil }
        return URL(string: assetFolderURLString)?.standardizedFileURL
    }
}
