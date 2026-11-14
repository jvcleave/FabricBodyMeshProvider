import BodyMeshProviderCore
import Satin

final class BuiltInCharacterRenderable
{
    let object: Object
    private let geometry: BodyMeshGeometry
    private let reconstructor: CoMotionMeshReconstructor
    private var mesh: Mesh?

    init(context: Context, reconstructor: CoMotionMeshReconstructor)
    {
        self.reconstructor = reconstructor
        geometry = BodyMeshGeometry(context: context)
        object = Object(context: context, label: "Built-in", visible: false)
    }

    func prepare(_ people: [CoMotionFramePerson]) throws
    {
        guard people.isEmpty == false
        else
        {
            clear()
            return
        }

        try geometry.replaceBodies(people, reconstructor: reconstructor)
        if mesh == nil
        {
            // Set the vertex layout before the material builds its first pipeline.
            geometry.updateGeometryData()
            let material = StandardMaterial(context: object.context)
            material.roughness = 0.65
            material.metallic = 0.0
            let mesh = Mesh(context: object.context, label: "Body", geometry: geometry, material: material)
            mesh.castShadow = true
            mesh.receiveShadow = true
            object.add(mesh)
            self.mesh = mesh
        }
        object.visible = true
    }

    func clear()
    {
        object.visible = false
    }
}
