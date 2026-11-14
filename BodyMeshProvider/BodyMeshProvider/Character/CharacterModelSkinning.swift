import MessUSDZImportKit
import Metal
import Satin
import simd

final class CharacterModelSkinning
{
    struct Output
    {
        let positions: MTLBuffer
        let normals: MTLBuffer
    }

    private struct Joint
    {
        let positionMatrix: simd_float4x4
        let normalMatrix: simd_float4x4
    }

    private struct BindVertex
    {
        let position: SIMD4<Float>
        let normal: SIMD4<Float>
    }

    private struct Influence
    {
        let joint: UInt32
        let weight: Float
    }

    let bindBounds: Bounds
    private let bindVertices: MTLBuffer
    private let influences: MTLBuffer
    private let layout: SIMD2<UInt32>
    var vertexCount: Int { Int(layout.x) }
    var inputBuffers: [MTLBuffer] { [bindVertices, influences] }

    init(device: MTLDevice, skin: USDZMeshSkin) throws
    {
        let vertices = zip(skin.positions, skin.normals).map { position, normal in
            BindVertex(position: SIMD4(position, 1), normal: SIMD4(normal, 0))
        }
        let jointWeights = skin.influences.map { Influence(joint: $0.joint, weight: $0.weight) }
        guard let bindVertices = Self.upload(vertices, device: device),
              let influences = Self.upload(jointWeights, device: device)
        else { throw CharacterModelError.resources("Could not allocate character skinning buffers.") }

        bindBounds = skin.positions.withUnsafeBufferPointer { positions in
            computeBoundsFromFloatData(
                positions.baseAddress,
                Int32(MemoryLayout<SIMD3<Float>>.stride / MemoryLayout<Float>.stride),
                Int32(positions.count)
            )
        }
        self.bindVertices = bindVertices
        self.influences = influences
        layout = SIMD2(UInt32(vertices.count), UInt32(skin.influencesPerVertex))
    }

    static func makePipeline(device: MTLDevice) throws -> MTLComputePipelineState
    {
        let bundle = Bundle(for: BodyMeshProviderPlugin.self)
        let library = try device.makeDefaultLibrary(bundle: bundle)
        guard let function = library.makeFunction(name: "skinCharacterSurface")
        else { throw CharacterModelError.resources("Character skinning shader is missing.") }
        return try device.makeComputePipelineState(function: function)
    }

    static func makePalette(_ matrices: [simd_float4x4], allocator: GPUAllocator) throws -> MTLBuffer
    {
        let palette = matrices.map { matrix in
            Joint(positionMatrix: matrix, normalMatrix: simd_transpose(simd_inverse(matrix)))
        }
        return try palette.withUnsafeBytes { bytes in
            let buffer = try allocator.makeBuffer(length: bytes.count, memoryClass: .cpuWrites)
            UnsafeMutableRawBufferPointer(start: buffer.contents(), count: bytes.count).copyMemory(from: bytes)
            return buffer
        }
    }

    func makeOutput(allocator: GPUAllocator) throws -> Output
    {
        let length = vertexCount * MemoryLayout<SIMD4<Float>>.stride
        return try Output(
            positions: allocator.makeBuffer(length: length, memoryClass: .gpuOnly),
            normals: allocator.makeBuffer(length: length, memoryClass: .gpuOnly)
        )
    }

    func encode(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        palette: MTLBuffer,
        output: Output
    )
    {
        var surfaceLayout = layout
        encoder.setBuffer(bindVertices, offset: 0, index: 0)
        encoder.setBuffer(influences, offset: 0, index: 1)
        encoder.setBuffer(palette, offset: 0, index: 2)
        encoder.setBuffer(output.positions, offset: 0, index: 3)
        encoder.setBuffer(output.normals, offset: 0, index: 4)
        encoder.setBytes(&surfaceLayout, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: vertexCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        )
    }

    private static func upload<Element>(_ elements: [Element], device: MTLDevice) -> MTLBuffer?
    {
        elements.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress, bytes.isEmpty == false else { return nil }
            return device.makeBuffer(bytes: source, length: bytes.count, options: .storageModeShared)
        }
    }
}
