import Foundation
import MessUSDZImportKit
import Metal
import Satin
import simd

/// Uses the same sampled alpha and cutoff for color and shadow depth.
final class CharacterTexturedMaterial: StandardMaterial
{
    private let pipelineURL: URL
    private let texture: MTLTexture
    private let sampler: MTLSamplerState
    private let hasCutout: Bool
    private let isUnlit: Bool

    override var lightingModel: LightingModel { isUnlit ? .unlit : .surface }
    override var supportedOutputs: RendererOutputs { isUnlit ? [.color] : super.supportedOutputs }

    init(context: Context, surface: CharacterModelImport.Surface, images: [String: USDZImage]) throws
    {
        let material = surface.material
        let opacity = material.maps["opacity"]
        guard let albedo = material.maps["diffuseColor"],
              surface.geometry.textureCoordinates != nil,
              albedo.uvSet == "st",
              let image = images[albedo.archivePath]
        else { throw CharacterModelError.surface(surface.sourcePath, "Missing character albedo or UVs") }

        if let opacity
        {
            guard albedo.archivePath == opacity.archivePath,
                  opacity.channel == "a",
                  albedo.uvSet == opacity.uvSet,
                  albedo.wrap == opacity.wrap,
                  albedo.wrapT == opacity.wrapT
            else { throw CharacterModelError.surface(surface.sourcePath, "Unsupported cutout texture binding") }
        }

        let bundle = Bundle(for: BodyMeshProviderPlugin.self)
        guard let shader = bundle.url(forResource: "CharacterTextured.metal", withExtension: "txt")
        else { throw CharacterModelError.resources("Character textured shader is missing.") }

        let isSRGB = albedo.colorSpace == "sRGB" || (albedo.colorSpace == "auto" && image.colorSpace == .sRGB)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: isSRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = try Self.addressMode(albedo.wrap, surface: surface.sourcePath)
        samplerDescriptor.tAddressMode = try Self.addressMode(albedo.wrapT, surface: surface.sourcePath)
        guard let texture = context.device.makeTexture(descriptor: descriptor),
              let sampler = context.device.makeSamplerState(descriptor: samplerDescriptor)
        else { throw CharacterModelError.resources("Could not allocate a character surface texture and sampler.") }

        image.rgba8Data.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress
            {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, image.width, image.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: image.width * 4
                )
            }
        }
        pipelineURL = shader
        self.texture = texture
        self.sampler = sampler
        hasCutout = material.opacityThreshold > 0
        isUnlit = material.isUnlit
        super.init(context: context)
        label = "CharacterTextured"
        lighting = !isUnlit
        roughness = material.roughness
        metallic = material.metallic
        set("Texture Scale", SIMD4(albedo.scale.x, albedo.scale.y, albedo.scale.z, opacity?.scale.w ?? 0))
        set("Texture Bias", SIMD4(albedo.bias.x, albedo.bias.y, albedo.bias.z, opacity?.bias.w ?? 1))
        set("Alpha Threshold", material.opacityThreshold)
    }

    required init(context: Context)
    {
        fatalError("A character textured material requires a validated surface.")
    }

    required init(from decoder: Decoder) throws
    {
        throw CharacterModelError.resources("Character materials are rebuilt from the model file.")
    }

    override func createShader() -> Shader
    {
        if hasCutout
        {
            return CharacterCutoutShader(context: context, label: label, pipelineURL: pipelineURL)
        }
        return StandardShader(context: context, label: label, pipelineURL: pipelineURL)
    }

    override func draw(in context: MaterialDrawContext) throws
    {
        try super.draw(in: context)
        if !context.isShadowPass || hasCutout
        {
            context.setFragmentPBRTexture(texture, type: .baseColor)
            context.setFragmentSamplerState(sampler, index: .Custom0)
        }
    }

    private static func addressMode(_ mode: String, surface: String) throws -> MTLSamplerAddressMode
    {
        switch mode
        {
            case "repeat": return .repeat
            case "clamp": return .clampToEdge
            case "mirror": return .mirrorRepeat
            case "black": return .clampToZero
            default: throw CharacterModelError.surface(surface, "Unsupported texture wrap mode")
        }
    }
}

private final class CharacterCutoutShader: StandardShader
{
    override func makeShadowPipeline() throws -> MTLRenderPipelineState?
    {
        let device = context.device
        guard let library = try ShaderLibraryCache.getLibrary(configuration: configuration.getLibraryConfiguration(), device: device),
              let vertex = library.makeFunction(name: shadowFunctionName),
              let fragment = library.makeFunction(name: "characterTexturedShadowFragment")
        else { throw CharacterModelError.resources("Character cutout shadow shader is missing.") }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Character Cutout Shadow"
        // All imported character surfaces use the same position, normal and UV layout.
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.depthAttachmentPixelFormat = .depth32Float
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
