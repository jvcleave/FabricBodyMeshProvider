import SwiftUI
import UniformTypeIdentifiers

struct BodyMeshProviderSettingsView: View
{
    @Bindable var model: BodyMeshProviderSettingsModel

    var body: some View
    {
        Form
        {
            Section("CoMotion Asset")
            {
                LabeledContent("Folder")
                {
                    Text(model.assetFolderDisplayName)
                        .foregroundStyle(model.canReloadAsset ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack
                {
                    Button("Choose Asset Folder", systemImage: "folder")
                    {
                        model.isChoosingAssetFolder = true
                    }

                    if model.canReloadAsset
                    {
                        Button("Reload", systemImage: "arrow.clockwise")
                        {
                            model.requestReload()
                        }

                        Button("Clear", systemImage: "xmark.circle")
                        {
                            model.clearAssetFolder()
                        }
                    }
                }

                if let importErrorMessage = model.importErrorMessage
                {
                    Text(importErrorMessage)
                        .foregroundStyle(.red)
                }

                Text("Choose a folder produced by CMResearchKit that contains frames.bin. If asset.json is present, the plug-in validates it against the archive.")
                    .foregroundStyle(.secondary)
            }

            Section("Asset Status")
            {
                LabeledContent("Asset", value: model.runtimeStatus.assetDisplayName)
                LabeledContent("Compatibility", value: model.compatibilityDescription)

                if let nativeFrameRateDescription = model.nativeFrameRateDescription
                {
                    LabeledContent("Native Frame Rate", value: nativeFrameRateDescription)
                }
                if let frameCountDescription = model.frameCountDescription
                {
                    LabeledContent("Frame Count", value: frameCountDescription)
                }
                if let durationDescription = model.durationDescription
                {
                    LabeledContent("Duration", value: durationDescription)
                }
                if let errorMessage = model.runtimeStatus.errorMessage
                {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $model.isChoosingAssetFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        )
        { result in
            switch result
            {
                case let .success(urls):
                    guard let selectedURL = urls.first else { return }
                    model.selectAssetFolder(selectedURL)
                case let .failure(error):
                    model.reportImportError(error)
            }
        }
    }
}
