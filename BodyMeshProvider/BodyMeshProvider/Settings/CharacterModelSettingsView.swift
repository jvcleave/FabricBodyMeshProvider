import SwiftUI
import UniformTypeIdentifiers

struct CharacterModelSettingsView: View
{
    @State var modelURL: URL?
    let archiveURL: URL?
    let selectModel: (URL?) -> Void
    let selectArchive: (URL?) -> Void

    @State private var isChoosingModel = false

    var body: some View
    {
        Form
        {
            Section("Character Model")
            {
                Text(modelURL?.lastPathComponent ?? "Built-in")
                Button("Choose Character Model", systemImage: "folder")
                {
                    isChoosingModel = true
                }
                if modelURL != nil
                {
                    Button("Use Built-in", systemImage: "person")
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

            MotionArchiveSettingsSection(archiveURL: archiveURL, selectArchive: selectArchive)
        }
        .formStyle(.grouped)
    }
}
