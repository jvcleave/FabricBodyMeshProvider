import SwiftUI
import UniformTypeIdentifiers

struct CharacterModelSettingsView: View
{
    let modelURL: URL?
    let archiveURL: URL?
    let selectModel: (URL?) -> Void
    let selectArchive: (URL?) -> Void

    var body: some View
    {
        Form
        {
            CharacterModelSettingsSection(modelURL: modelURL, allowsBuiltIn: true, selectModel: selectModel)
            MotionArchiveSettingsSection(archiveURL: archiveURL, selectArchive: selectArchive)
        }
        .formStyle(.grouped)
    }
}

struct CharacterModelSettingsSection: View
{
    @State var modelURL: URL?
    let allowsBuiltIn: Bool
    let selectModel: (URL?) -> Void

    @State private var isChoosingModel = false

    var body: some View
    {
        Section("Character Model")
        {
            Text(modelURL?.lastPathComponent ?? (allowsBuiltIn ? "Built-in" : "No model selected"))
            Button("Choose Character Model", systemImage: "folder")
            {
                isChoosingModel = true
            }
            if modelURL != nil
            {
                Button(
                    allowsBuiltIn ? "Use Built-in" : "Clear Character Model",
                    systemImage: allowsBuiltIn ? "person" : "xmark"
                )
                {
                    modelURL = nil
                    selectModel(nil)
                }
            }
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
