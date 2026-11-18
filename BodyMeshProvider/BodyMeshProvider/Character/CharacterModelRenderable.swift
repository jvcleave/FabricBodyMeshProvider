import BodyMeshProviderCore
import Foundation
import Metal
import MetalPerformanceShaders
import Satin
import os
import simd

final class CharacterModelRenderable
{
    private struct Surface
    {
        let sourcePath: String
        let materialPath: String
        let skinning: CharacterModelSkinning
        let topology: CharacterModelGeometry.Topology
        let material: Material
        let isDoubleSided: Bool
    }

    private struct SurfaceInstance
    {
        let mesh: Mesh
        let geometry: CharacterModelGeometry
    }

    private struct Body
    {
        let object: Object
        let surfaces: [SurfaceInstance]
    }

    let object: Object
    private let context: Context
    private let rig: CoMotionCharacterRig
    private let surfaces: [Surface]
    private let pipeline: MTLComputePipelineState
    private var pose: [Pose] = []
    private var poseCompletion: OSAllocatedUnfairLock<Bool>?
    private var bodies: [Body] = []
    private var overrides = CharacterOverrides()

    convenience init(context: Context, sourceURL: URL) throws
    {
        let model = try BodyMeshProviderResources.waitForSource { try await CharacterModelImport.load(sourceURL) }
        try self.init(context: context, model: model)
    }

    init(context: Context, model: CharacterModelImport) throws
    {
        self.context = context
        rig = model.rig
        object = Object(context: context, label: "Character Model")
        pipeline = try CharacterModelSkinning.makePipeline(device: context.device)
        surfaces = try model.surfaces.map { surface in
            try Surface(
                sourcePath: surface.sourcePath,
                materialPath: surface.material.path,
                skinning: CharacterModelSkinning(device: context.device, skin: surface.skin),
                topology: CharacterModelGeometry.Topology(mesh: surface.geometry),
                material: Self.makeMaterial(surface, model: model, context: context),
                isDoubleSided: surface.isDoubleSided
            )
        }
    }

    func prepareReferencePose()
    {
        setPose([Pose(matrices: rig.referenceMatrices, translation: .zero)])
    }

    func prepare(_ people: [CoMotionRigPerson]) throws
    {
        let poses = try people.map { person in
            let translation = person.translation
            return try Pose(
                matrices: rig.skinningMatrices(person.skinningTransforms),
                translation: SIMD3(translation[0], -translation[1], -translation[2])
            )
        }
        setPose(poses)
    }

    func clear()
    {
        setPose([])
        object.visible = false
    }

    func setOverrides(_ overrides: CharacterOverrides)
    {
        guard self.overrides != overrides else { return }
        self.overrides = overrides
        for body in bodies
        {
            for (surface, instance) in zip(surfaces, body.surfaces)
            {
                let appearance = appearance(for: surface)
                if instance.mesh.visible != appearance.visible { instance.mesh.visible = appearance.visible }
                if instance.mesh.material !== appearance.material
                {
                    instance.mesh.material = appearance.material
                    instance.mesh.receiveShadow = appearance.material.lighting
                }
            }
        }
    }

    private func appearance(for surface: Surface) -> (visible: Bool, material: Material)
    {
        let visible = overrides.meshVisibility[surface.sourcePath] != false
            && overrides.materialVisibility[surface.materialPath] != false
        return (visible, overrides.materials[surface.materialPath] ?? surface.material)
    }

    var captureBounds: Bounds?
    {
        guard object.visible, !pose.isEmpty else { return nil }
        var bounds = createBounds()
        for body in bodies.prefix(pose.count)
        {
            for surface in body.surfaces where surface.mesh.visible
            {
                bounds = mergeBounds(bounds, transformBounds(surface.geometry.bounds, body.object.localMatrix))
            }
        }
        return bounds
    }

    private func setPose(_ pose: [Pose])
    {
        self.pose = pose
        poseCompletion = nil
    }

    private struct Pose
    {
        let matrices: [simd_float4x4]
        let translation: SIMD3<Float>
    }

    private struct PreparedBody
    {
        let palette: MTLBuffer
        let outputs: [CharacterModelSkinning.Output]
        let bounds: [Bounds]
    }

    func encode(commandBuffer: MTLCommandBuffer) throws
    {
        guard pose.isEmpty == false
        else
        {
            object.visible = false
            return
        }
        guard poseCompletion?.withLock({ $0 }) != true else { return }

        // Each encoded pose owns its writable buffers. Fabric can retain a draw
        // packet while another evaluation prepares the same meshes.
        let prepared = try pose.map { pose in
            try PreparedBody(
                palette: CharacterModelSkinning.makePalette(pose.matrices, allocator: context.gpuAllocator),
                outputs: surfaces.map { try $0.skinning.makeOutput(allocator: context.gpuAllocator) },
                bounds: surfaces.map { surface in
                    // Positive, normalized weights keep the posed vertices inside this union.
                    pose.matrices.reduce(createBounds()) { bounds, matrix in
                        mergeBounds(bounds, transformBounds(surface.skinning.bindBounds, matrix))
                    }
                }
            )
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder()
        else { throw CharacterModelError.resources("Could not encode character skinning.") }
        encoder.label = "Character Model Skinning"
        encoder.setComputePipelineState(pipeline)
        for body in prepared
        {
            for (surface, output) in zip(surfaces, body.outputs)
            {
                surface.skinning.encode(encoder: encoder, pipeline: pipeline, palette: body.palette, output: output)
            }
        }
        encoder.endEncoding()

        let segment = (commandBuffer as? MPSCommandBuffer)?.rootCommandBuffer ?? commandBuffer
        let inputs = segment.retainedReferences ? [] : surfaces.flatMap { $0.skinning.inputBuffers }
        let completion = OSAllocatedUnfairLock(initialState: false)
        poseCompletion = completion
        segment.addCompletedHandler { [inputs, prepared] completed in
            if completed.status == .completed { completion.withLock { $0 = true } }
            withExtendedLifetime(inputs) {}
            withExtendedLifetime(prepared) {}
        }

        for (bodyIndex, body) in prepared.enumerated()
        {
            if bodyIndex == bodies.count
            {
                bodies.append(makeBody(body))
            }
            else
            {
                for (surfaceIndex, surface) in bodies[bodyIndex].surfaces.enumerated()
                {
                    surface.geometry.apply(body.outputs[surfaceIndex], bounds: body.bounds[surfaceIndex])
                }
            }
            let instance = bodies[bodyIndex]
            instance.object.position = pose[bodyIndex].translation
            instance.object.visible = true
        }
        for body in bodies.dropFirst(pose.count) { body.object.visible = false }
        object.visible = true
    }

    private func makeBody(_ body: PreparedBody) -> Body
    {
        let instance = Object(context: context, label: "Character")
        let instances = surfaces.enumerated().map { surfaceIndex, surface in
            let geometry = CharacterModelGeometry(context: context, topology: surface.topology)
            geometry.apply(body.outputs[surfaceIndex], bounds: body.bounds[surfaceIndex])
            let appearance = appearance(for: surface)
            let mesh = Mesh(context: context, label: surface.sourcePath, geometry: geometry, material: appearance.material, visible: appearance.visible)
            mesh.doubleSided = surface.isDoubleSided
            mesh.cullMode = surface.isDoubleSided ? .none : .back
            mesh.castShadow = true
            mesh.receiveShadow = appearance.material.lighting
            instance.add(mesh)
            return SurfaceInstance(mesh: mesh, geometry: geometry)
        }
        object.add(instance)
        return Body(object: instance, surfaces: instances)
    }

    private static func makeMaterial(
        _ surface: CharacterModelImport.Surface,
        model: CharacterModelImport,
        context: Context
    ) throws -> Material
    {
        let authored = surface.material
        guard authored.usesVertexColors == false,
              authored.usesVertexOpacity == false,
              authored.specularColor == nil,
              authored.opacity == 1,
              authored.emission == .zero
        else { throw CharacterModelError.surface(surface.sourcePath, "Unsupported surface material") }

        if authored.maps.isEmpty, authored.opacityThreshold == 0
        {
            if authored.isUnlit
            {
                return BasicColorMaterial(context: context, color: SIMD4(authored.baseColor, 1))
            }
            let material = StandardMaterial(context: context)
            material.baseColor = SIMD4(authored.baseColor, 1)
            material.roughness = authored.roughness
            material.metallic = authored.metallic
            return material
        }

        let hasCutout = authored.opacityThreshold > 0
        let supportedMaps: Set<String> = hasCutout ? ["diffuseColor", "opacity"] : ["diffuseColor"]
        guard Set(authored.maps.keys) == supportedMaps
        else { throw CharacterModelError.surface(surface.sourcePath, "Unsupported texture workflow") }
        return try CharacterTexturedMaterial(context: context, surface: surface, images: model.images)
    }
}
