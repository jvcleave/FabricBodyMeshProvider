import Foundation
import os

/// Holds one immutable import for all active users of a file. The lock guards
/// source identity. File I/O and waiting happen outside it.
final class CharacterModelSource: Sendable
{
    private struct Entry: Sendable
    {
        weak var source: CharacterModelSource?
    }

    private static let sources = OSAllocatedUnfairLock(initialState: [URL: Entry]())

    let url: URL
    private let importTask: Task<CharacterModelImport, any Error>

    private init(url: URL)
    {
        self.url = url
        importTask = Task.detached(priority: .userInitiated) { try await CharacterModelImport.load(url) }
    }

    static func source(for url: URL) -> CharacterModelSource
    {
        sources.withLock { sources in
            if let source = sources[url]?.source { return source }
            sources = sources.filter { $0.value.source != nil }
            let source = CharacterModelSource(url: url)
            sources[url] = Entry(source: source)
            return source
        }
    }

    func load() throws -> CharacterModelImport
    {
        try BodyMeshProviderResources.waitForSource { try await self.importTask.value }
    }

    func inspectorTargets() async throws -> [CharacterInspectorSettings.Target]
    {
        try await importTask.value.inspectorTargets
    }
}
