import SwiftUI
import UniformTypeIdentifiers

struct CharacterModelSettingsView: View
{
    let settings: CharacterModelSettings
    let selectModel: (URL?) -> Void
    let selectArchive: (URL?) -> Void
    let setModelPathStorage: (Bool) -> Void
    let setArchivePathStorage: (Bool) -> Void

    var body: some View
    {
        Form
        {
            CharacterModelSettingsSection(
                modelURL: settings.characterModelURL,
                allowsBuiltIn: true,
                storesAbsolutePath: settings.storeAbsoluteModelPath == true,
                selectModel: selectModel,
                setPathStorage: setModelPathStorage
            )
            MotionArchiveSettingsSection(
                archiveURL: settings.motionArchiveURL,
                storesAbsolutePath: settings.storeAbsoluteArchivePath == true,
                selectArchive: selectArchive,
                setPathStorage: setArchivePathStorage
            )
        }
        .formStyle(.grouped)
    }
}

struct CharacterModelSettingsSection: View
{
    @State var modelURL: URL?
    let allowsBuiltIn: Bool
    let storesAbsolutePath: Bool
    let selectModel: (URL?) -> Void
    let setPathStorage: (Bool) -> Void

    @State private var isChoosingModel = false

    var body: some View
    {
        Section("Character Model")
        {
            Text(modelURL?.lastPathComponent ?? (allowsBuiltIn ? "Default Human" : "No model selected"))
            Button("Choose Character Model", systemImage: "folder")
            {
                isChoosingModel = true
            }
            if modelURL != nil
            {
                Button(
                    allowsBuiltIn ? "Use Default Human" : "Clear Character Model",
                    systemImage: allowsBuiltIn ? "person" : "xmark"
                )
                {
                    modelURL = nil
                    selectModel(nil)
                }
            }
            StoreAbsolutePathToggle(isOn: storesAbsolutePath, update: setPathStorage)
        }
        .fileImporter(isPresented: $isChoosingModel, allowedContentTypes: [.usdz]) { result in
            if case let .success(url) = result
            {
                let selectedURL = url.standardizedFileURL
                modelURL = selectedURL
                selectModel(selectedURL)
            }
        }
    }
}

struct StoreAbsolutePathToggle: View
{
    @State var isOn: Bool
    let update: (Bool) -> Void

    var body: some View
    {
        Toggle("Store Absolute Path", isOn: Binding(
            get: { isOn },
            set: { newValue in
                isOn = newValue
                update(newValue)
            }
        ))
        .help("Keep pointing to this location when the scene moves.")
    }
}
