import Observation
import SwiftUI

@MainActor @Observable
final class CharacterInspectorSettingsModel
{
    typealias Target = CharacterInspectorSettings.Target

    struct Section: Identifiable
    {
        let id: Target.Kind
        let title: String
        let rows: [Row]
    }

    struct Row: Identifiable
    {
        let target: Target
        let isExposed: Bool
        let isMissing: Bool

        var id: String { target.id }
    }

    private(set) var sections: [Section] = []
    private(set) var status: String? = "Connect a character asset."
    @ObservationIgnored private var settings = CharacterInspectorSettings(targets: [])
    @ObservationIgnored private var source: CharacterModelSource?
    @ObservationIgnored private var catalog: [Target]?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let updateSettings: (CharacterInspectorSettings) -> Void

    init(updateSettings: @escaping (CharacterInspectorSettings) -> Void)
    {
        self.updateSettings = updateSettings
    }

    deinit { loadTask?.cancel() }

    func synchronize(settings: CharacterInspectorSettings, source: CharacterModelSource?)
    {
        self.settings = settings
        if self.source !== source
        {
            self.source = source
            loadTask?.cancel()
            catalog = nil
            if let source
            {
                status = "Loading \(source.url.lastPathComponent)…"
                loadTask = Task { [weak self] in
                    do
                    {
                        let catalog = try await source.inspectorTargets()
                        guard !Task.isCancelled, let self else { return }
                        self.catalog = catalog
                        status = nil
                        rebuildRows()
                    }
                    catch
                    {
                        guard !Task.isCancelled else { return }
                        self?.status = error.localizedDescription
                    }
                }
            }
            else
            {
                loadTask = nil
                status = "Connect a character asset."
            }
        }
        rebuildRows()
    }

    func setExposed(_ exposed: Bool, target: Target)
    {
        var targets = settings.targets.filter { $0.id != target.id }
        if exposed { targets.append(target) }
        settings = CharacterInspectorSettings(targets: targets)
        rebuildRows()
        updateSettings(settings)
    }

    private func rebuildRows()
    {
        let exposedIDs = Set(settings.targets.map(\.id))
        let available = catalog ?? []
        let availableIDs = Set(available.map(\.id))
        let targets = available + settings.targets.filter { !availableIDs.contains($0.id) }
        let groups: [(Target.Kind, String)] = [
            (.meshVisibility, "Mesh Visibility Inlets"),
            (.materialVisibility, "Material Visibility Inlets"),
            (.material, "Material Replacement Inlets"),
        ]
        sections = groups.compactMap { kind, title in
            let rows = targets.filter { $0.kind == kind }.map { target in
                Row(target: target, isExposed: exposedIDs.contains(target.id), isMissing: catalog != nil && !availableIDs.contains(target.id))
            }
            return rows.isEmpty ? nil : Section(id: kind, title: title, rows: rows)
        }
    }
}

struct CharacterInspectorSettingsView: View
{
    let model: CharacterInspectorSettingsModel

    var body: some View
    {
        Form
        {
            if let status = model.status { Text(status).foregroundStyle(.secondary) }
            ForEach(model.sections) { section in
                Section(section.title)
                {
                    ForEach(section.rows) { row in
                        Toggle(isOn: Binding(get: { row.isExposed }, set: { model.setExposed($0, target: row.target) }))
                        {
                            VStack(alignment: .leading)
                            {
                                Text(row.target.portName)
                                Text(row.target.path).font(.caption).foregroundStyle(.secondary)
                                if row.isMissing { Text("Unavailable on this character").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
