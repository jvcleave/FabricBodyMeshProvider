import BodyMeshProviderCore
import Foundation

/// A frame and its archive metadata, carried by Fabric's dictionary-of-float-arrays port.
struct CoMotionFramePayload
{
    typealias Values = [String: ContiguousArray<Float>]

    let frameIndex: Int
    let frameCount: Int
    let frameRate: Float
    let sourceSize: SIMD2<Float>
    let people: [CoMotionFramePerson]

    init(frame: CoMotionFrame, archive: CoMotionArchiveReader)
    {
        frameIndex = frame.videoFrameOrdinal
        frameCount = archive.frameCount
        frameRate = archive.metadata.encodedFrameRate
        sourceSize = archive.metadata.sourceSize
        if case let .available(detections) = frame.status { people = detections }
        else { people = [] }
    }

    var values: Values
    {
        [
            "frameIndex": [Float(frameIndex)],
            "frameCount": [Float(frameCount)],
            "frameRate": [frameRate],
            "sourceSize": [sourceSize.x, sourceSize.y],
            "confidence": ContiguousArray(people.map(\.confidence)),
            "betas": ContiguousArray(people.lazy.flatMap(\.meshParameters.betas)),
            "poseFeatures": ContiguousArray(people.lazy.flatMap(\.meshParameters.poseFeature)),
            "skinningTransforms": ContiguousArray(people.lazy.flatMap(\.meshParameters.skinningTransforms)),
            "translations": ContiguousArray(people.lazy.flatMap(\.meshParameters.translation)),
        ]
    }

    init(values: Values) throws
    {
        guard let index = Self.scalar("frameIndex", in: values).flatMap({ Int(exactly: $0) }),
              let count = Self.scalar("frameCount", in: values).flatMap({ Int(exactly: $0) }),
              count <= CoMotionArchiveFormat.maximumFrameCount, index >= 0, index < count,
              let rate = Self.scalar("frameRate", in: values),
              rate.isFinite, rate > 0, rate <= CoMotionArchiveFormat.maximumFrameRate,
              let dimensions = values["sourceSize"], dimensions.count == 2,
              dimensions.allSatisfy({ dimension in
                  guard let size = Int(exactly: dimension) else { return false }
                  return size > 0 && size <= CoMotionArchiveFormat.maximumDimension
              }),
              let confidence = values["confidence"],
              confidence.count <= CoMotionArchiveFormat.maximumPeoplePerFrame,
              confidence.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              let betas = values["betas"], betas.count == confidence.count * CoMotionMeshParameters.betaCount,
              let poseFeatures = values["poseFeatures"],
              poseFeatures.count == confidence.count * CoMotionMeshParameters.poseFeatureCount,
              let skinningTransforms = values["skinningTransforms"],
              skinningTransforms.count == confidence.count * CoMotionMeshParameters.skinningTransformCount,
              let translations = values["translations"],
              translations.count == confidence.count * CoMotionMeshParameters.translationCount
        else { throw BodyMeshProviderResourceError.invalidMotionFrame }

        frameIndex = index
        frameCount = count
        frameRate = rate
        sourceSize = SIMD2(dimensions[0], dimensions[1])
        people = try confidence.enumerated().map { personIndex, confidence in
            let parameters = try CoMotionMeshParameters(
                betas: Self.personValues(betas, count: CoMotionMeshParameters.betaCount, index: personIndex),
                poseFeature: Self.personValues(poseFeatures, count: CoMotionMeshParameters.poseFeatureCount, index: personIndex),
                skinningTransforms: Self.personValues(skinningTransforms, count: CoMotionMeshParameters.skinningTransformCount, index: personIndex),
                translation: Self.personValues(translations, count: CoMotionMeshParameters.translationCount, index: personIndex)
            )
            return CoMotionFramePerson(confidence: confidence, meshParameters: parameters)
        }
    }

    private static func scalar(_ name: String, in values: Values) -> Float?
    {
        guard let field = values[name], field.count == 1 else { return nil }
        return field[0]
    }

    private static func personValues(_ values: ContiguousArray<Float>, count: Int, index: Int) -> [Float]
    {
        let start = index * count
        return Array(values[start ..< start + count])
    }
}
