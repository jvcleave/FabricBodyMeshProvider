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
    let people: [CoMotionRigPerson]
    let values: Values

    init(frameIndex: Int, archive: CoMotionArchiveReader) throws
    {
        self.frameIndex = frameIndex
        frameCount = archive.frameCount
        frameRate = archive.metadata.encodedFrameRate
        sourceSize = archive.metadata.sourceSize

        var fields: Values = [
            "frameIndex": [Float(frameIndex)],
            "frameCount": [Float(frameCount)],
            "frameRate": [frameRate],
            "sourceSize": [sourceSize.x, sourceSize.y],
        ]
        if archive.formatVersion == CoMotionArchiveFormat.rigFormatVersion
        {
            people = try archive.rigPeople(at: frameIndex)
            fields["formatVersion"] = [Float(CoMotionArchiveFormat.rigFormatVersion)]
        }
        else
        {
            let frame = try archive.frameAtIndex(frameIndex)
            let detections: [CoMotionFramePerson]
            if case let .available(framePeople) = frame.status { detections = framePeople }
            else { detections = [] }
            people = detections.map(\.rigPerson)
            // Keep the shape fields that existing v2 graphs receive.
            fields["betas"] = ContiguousArray(detections.lazy.flatMap(\.meshParameters.betas))
            fields["poseFeatures"] = ContiguousArray(detections.lazy.flatMap(\.meshParameters.poseFeature))
        }
        fields["confidence"] = ContiguousArray(people.map(\.confidence))
        fields["skinningTransforms"] = ContiguousArray(people.lazy.flatMap(\.skinningTransforms))
        fields["translations"] = ContiguousArray(people.lazy.flatMap { [$0.translation.x, $0.translation.y, $0.translation.z] })
        values = fields
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
              let skinningTransforms = values["skinningTransforms"],
              skinningTransforms.count == confidence.count * CoMotionMeshParameters.skinningTransformCount,
              skinningTransforms.allSatisfy(\.isFinite),
              let translations = values["translations"],
              translations.count == confidence.count * CoMotionMeshParameters.translationCount,
              translations.allSatisfy(\.isFinite)
        else { throw BodyMeshProviderResourceError.invalidMotionFrame }

        if let version = values["formatVersion"]
        {
            guard version == [Float(CoMotionArchiveFormat.rigFormatVersion)],
                  values["betas"] == nil, values["poseFeatures"] == nil
            else { throw BodyMeshProviderResourceError.invalidMotionFrame }
        }
        else
        {
            guard let betas = values["betas"], betas.count == confidence.count * CoMotionMeshParameters.betaCount,
                  betas.allSatisfy(\.isFinite),
                  let poseFeatures = values["poseFeatures"], poseFeatures.count == confidence.count * CoMotionMeshParameters.poseFeatureCount,
                  poseFeatures.allSatisfy(\.isFinite)
            else { throw BodyMeshProviderResourceError.invalidMotionFrame }
        }

        frameIndex = index
        frameCount = count
        frameRate = rate
        sourceSize = SIMD2(dimensions[0], dimensions[1])
        people = confidence.enumerated().map { personIndex, confidence in
            let translationOffset = personIndex * CoMotionMeshParameters.translationCount
            return CoMotionRigPerson(
                confidence: confidence,
                skinningTransforms: Self.personValues(skinningTransforms, count: CoMotionMeshParameters.skinningTransformCount, index: personIndex),
                translation: SIMD3(translations[translationOffset], translations[translationOffset + 1], translations[translationOffset + 2])
            )
        }
        self.values = values
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
