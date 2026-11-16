import SwiftUI
import UniformTypeIdentifiers

struct MotionArchiveSettingsSection: View
{
    @State var archiveURL: URL?
    let storesAbsolutePath: Bool
    let selectArchive: (URL?) -> Void
    let setPathStorage: (Bool) -> Void

    @State private var isChoosingArchive = false

    var body: some View
    {
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
            StoreAbsolutePathToggle(isOn: storesAbsolutePath, update: setPathStorage)
        }
        .fileImporter(
            isPresented: $isChoosingArchive,
            allowedContentTypes: [
                .folder,
                UTType(filenameExtension: "messcapture", conformingTo: .package) ?? .package,
                UTType(filenameExtension: "bin") ?? .data,
            ]
        ) { result in
            if case let .success(url) = result
            {
                let selectedURL = url.standardizedFileURL
                archiveURL = selectedURL
                selectArchive(selectedURL)
            }
        }
    }
}
