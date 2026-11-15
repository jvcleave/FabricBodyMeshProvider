import Fabric
import Foundation
import Satin

struct CharacterOverrides: Equatable
{
    var meshVisibility: [String: Bool] = [:]
    var materialVisibility: [String: Bool] = [:]
    var materials: [String: Material] = [:]
}

/// The Character wire carries either a plain file reference or an inspected
/// reference with live overrides. Fabric serializes the ports and their wires.
struct CharacterReference
{
    private enum Key
    {
        static let file = "bodyMeshCharacterFile"
        static let meshVisibility = "meshVisibility"
        static let materialVisibility = "materialVisibility"
        static let materials = "materials"
    }

    let file: String
    var overrides = CharacterOverrides()

    init?(value: PortValue?) throws
    {
        guard let value else { return nil }
        switch value
        {
            case .String(let file):
                guard !file.isEmpty else { return nil }
                self.file = file
            case .Dictionary(let fields):
                guard case .String(let file) = fields[Key.file], !file.isEmpty,
                      let meshVisibility = [String: Bool].fromPortValue(fields[Key.meshVisibility] ?? .Dictionary([:])),
                      let materialVisibility = [String: Bool].fromPortValue(fields[Key.materialVisibility] ?? .Dictionary([:])),
                      let materials = [String: Material].fromPortValue(fields[Key.materials] ?? .Dictionary([:]))
                else { throw CharacterModelError.resources("The Character input has invalid overrides.") }
                self.file = file
                overrides = CharacterOverrides(meshVisibility: meshVisibility, materialVisibility: materialVisibility, materials: materials)
            default:
                throw CharacterModelError.resources("Connect a Character output or supply a mapped Creator USDZ file reference.")
        }
    }

    func fileURL(relativeTo directory: URL?) throws -> URL
    {
        guard let url = URL(fileReference: file, relativeTo: directory), url.pathExtension.lowercased() == "usdz"
        else { throw CharacterModelError.resources("Choose a local mapped Creator USDZ for the Character input.") }
        return url
    }

    var portValue: PortValue
    {
        if overrides == CharacterOverrides() { return .String(file) }
        return .Dictionary([
            Key.file: .String(file),
            Key.meshVisibility: overrides.meshVisibility.toPortValue(),
            Key.materialVisibility: overrides.materialVisibility.toPortValue(),
            Key.materials: overrides.materials.toPortValue(),
        ])
    }
}
