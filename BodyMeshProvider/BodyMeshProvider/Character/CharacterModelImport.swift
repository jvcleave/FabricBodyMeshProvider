import BodyMeshProviderCore
import Foundation
import MessUSDZImportKit
import simd

struct CharacterModelImport: Sendable
{
    let rig: CoMotionCharacterRig
    let surfaces: [Surface]
    let images: [String: USDZImage]

    struct Surface: Sendable
    {
        let sourcePath: String
        let geometry: USDZMesh
        let skin: USDZMeshSkin
        let material: USDZMaterial
        let isDoubleSided: Bool
    }

    static func load(_ url: URL) async throws -> CharacterModelImport
    {
        let model = try await USDZImporter(fileAccess: CharacterModelFiles()).importFile(
            url,
            includeMappedSkeletons: true
        )
        let rigPath = "/Human/Rig"
        guard model.sourceMetadata.upAxis == .y,
              model.sourceMetadata.metersPerUnit == 1,
              model.skeletons.count == 1,
              let skeleton = model.skeletons[rigPath],
              skeleton.worldTransform == matrix_identity_float4x4,
              skeleton.coMotionJointMap.version == 1,
              skeleton.coMotionJointMap.sourceIndices.count == skeleton.joints.count
        else { throw CharacterModelError.rig }
        let rig = try CoMotionCharacterRig(joints: zip(skeleton.joints, skeleton.coMotionJointMap.sourceIndices).map { joint, source in
            CoMotionCharacterRig.Joint(
                parent: joint.parent,
                source: source,
                localReference: joint.localReferenceTransform,
                inverseBind: joint.inverseBindTransform
            )
        })

        for issue in model.issues
        {
            // A baked clip belongs to the source USDZ and is deliberately not retained here.
            if issue.disposition == .sceneContentSkipped, issue.sourcePath == skeleton.animationPath,
               case .unsupportedContent("SkelAnimation") = issue.reason
            {
                continue
            }
            throw CharacterModelError.surface(issue.sourcePath, issue.reason.localizedDescription)
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, $0) })
        let materialsByPath = Dictionary(uniqueKeysWithValues: model.materials.map { ($0.path, $0) })
        var surfaces: [Surface] = []
        for node in model.nodes where node.parts.isEmpty == false
        {
            var ancestor: USDZNode? = node
            while let current = ancestor, current.isEnabled
            {
                ancestor = current.parentID.flatMap { nodesByID[$0] }
            }
            guard ancestor == nil else { continue }

            for part in node.parts
            {
                guard let skin = part.skin,
                      skin.skeletonPath == rigPath,
                      skin.positions.count == part.geometry.vertexCount,
                      skin.isValid(jointCount: skeleton.joints.count),
                      part.geometry.triangleIndices.isEmpty == false
                else { throw CharacterModelError.surface(node.sourcePath, "Invalid mapped skin") }

                guard let materialPath = part.materialPath, let material = materialsByPath[materialPath]
                else { throw CharacterModelError.surface(node.sourcePath, "Missing material") }

                surfaces.append(Surface(
                    sourcePath: node.sourcePath,
                    geometry: part.geometry,
                    skin: skin,
                    material: material,
                    isDoubleSided: part.isDoubleSided
                ))
            }
        }
        guard surfaces.contains(where: { $0.sourcePath == "/Human/body" })
        else { throw CharacterModelError.rig }

        return CharacterModelImport(rig: rig, surfaces: surfaces, images: model.images)
    }
}

enum CharacterModelError: LocalizedError
{
    case rig
    case surface(String, String)
    case resources(String)

    var errorDescription: String?
    {
        switch self
        {
            case .rig:
                return "The character requires a visible body and a version 1 mapped rig at /Human/Rig in Y-up meters."
            case let .surface(path, reason):
                return "\(path): \(reason)"
            case let .resources(reason):
                return reason
        }
    }
}

private struct CharacterModelFiles: USDZFileAccess
{
    func readData(_ url: URL, maximumBytes: Int) async throws -> Data
    {
        guard let stream = InputStream(url: url) else { throw USDZImportError.sourceUnavailable }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true
        {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw USDZImportError.sourceUnavailable }
            guard count <= maximumBytes - data.count else { throw USDZImportError.capacityExceeded }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }

    func withTemporaryDirectory<Result: Sendable>(
        _ operation: @Sendable (URL) async throws -> Result
    ) async throws -> Result
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FabricCharacter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}
