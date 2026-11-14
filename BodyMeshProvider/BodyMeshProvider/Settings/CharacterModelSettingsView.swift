import SwiftUI
import UniformTypeIdentifiers

struct CharacterModelSettingsView: View
{
    @State var modelURL: URL?
    @State var archiveURL: URL?
    let selectModel: (URL?) -> Void
    let selectArchive: (URL?) -> Void

    @State private var isChoosingModel = false
    @State private var isChoosingArchive = false

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

            Section("Motion Archive")
            {
                if let archiveURL { Text(archiveURL.lastPathComponent) }
                Button("Choose Motion Archive", systemImage: "folder")
                {
                    isChoosingArchive = true
                }
                if archiveURL != nil
                {
                    Button("Clear Motion Archive", systemImage: "xmark.circle")
                    {
                        archiveURL = nil
                        selectArchive(nil)
                    }
                }
            }
            .fileImporter(
                isPresented: $isChoosingArchive,
                allowedContentTypes: [.folder, UTType(filenameExtension: "messcapture", conformingTo: .package) ?? .package]
            ) { result in
                if case let .success(url) = result
                {
                    let selectedURL = url.standardizedFileURL
                    archiveURL = selectedURL
                    selectArchive(selectedURL)
                }
            }
        }
        .formStyle(.grouped)
    }
}
