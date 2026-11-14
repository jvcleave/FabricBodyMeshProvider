import Foundation
import MessUSDZImportKit
import Metal
import Satin
import simd

final class CharacterModelGeometry: Geometry
{
    struct Topology
    {
        let vertexCount: Int
        let texcoords: Float2BufferAttribute?
        let elements: ElementBuffer

        init(mesh: USDZMesh)
        {
            vertexCount = mesh.vertexCount
            texcoords = mesh.textureCoordinates.map { Float2BufferAttribute(defaultValue: .zero, data: $0) }
            let indexData = mesh.triangleIndices.withUnsafeBytes { NSMutableData(data: Data($0)) }
            elements = ElementBuffer(
                type: .uint32,
                data: indexData.mutableBytes,
                count: mesh.triangleIndices.count,
                source: indexData
            )
        }
    }

    private let count: Int
    private var posedBounds = createBounds()

    init(context: Context, topology: Topology)
    {
        count = topology.vertexCount
        super.init(context: context)
        if let texcoords = topology.texcoords { addAttribute(texcoords, for: .Texcoord) }
        setElements(topology.elements)
    }

    func apply(_ output: CharacterModelSkinning.Output, bounds: Bounds)
    {
        posedBounds = bounds
        addAttribute(CharacterOutputAttribute(buffer: output.positions, count: count), for: .Position)
        addAttribute(CharacterOutputAttribute(buffer: output.normals, count: count), for: .Normal)
    }

    override func computeBounds() -> Bounds { posedBounds }
}

private final class CharacterOutputAttribute: BufferAttribute
{
    // Satin shaders take float3 for both attributes, with the stride of the Metal float4 outputs.
    override var type: AttributeType { .float3 }
    override var count: Int { vertexCount }
    override var stride: Int { MemoryLayout<SIMD4<Float>>.stride }
    override var alignment: Int { MemoryLayout<SIMD4<Float>>.alignment }
    override var size: Int { MemoryLayout<SIMD3<Float>>.size }
    override var components: Int { 3 }

    private let vertexCount: Int

    init(buffer: MTLBuffer, count: Int)
    {
        vertexCount = count
        super.init()
        self.buffer = buffer
    }

    required init(from decoder: Decoder) throws
    {
        throw CharacterModelError.resources("Character vertex buffers are rebuilt from the model file.")
    }

    override func getBuffer(device: MTLDevice) -> MTLBuffer? { buffer }
}
