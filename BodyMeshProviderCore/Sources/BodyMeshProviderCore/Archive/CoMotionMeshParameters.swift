import Foundation

public enum CoMotionMeshParametersError: LocalizedError, Equatable, Sendable
{
    case invalidCount(name: String, expected: Int, actual: Int)
    case nonFiniteValue(name: String)

    public var errorDescription: String?
    {
        switch self
        {
            case let .invalidCount(name, expected, actual):
                return "CoMotion \(name) contains \(actual) values; expected \(expected)."
            case let .nonFiniteValue(name):
                return "CoMotion \(name) contains a non-finite value."
        }
    }
}

public struct CoMotionMeshParameters: Equatable, Sendable
{
    public static let betaCount = 10
    public static let poseFeatureCount = 207
    public static let skinningTransformCount = 24 * 16
    public static let translationCount = 3
    public static let totalFloatCount = betaCount + poseFeatureCount
        + skinningTransformCount + translationCount

    public let betas: [Float]
    public let poseFeature: [Float]
    public let skinningTransforms: [Float]
    public let translation: [Float]

    public init(
        betas: [Float],
        poseFeature: [Float],
        skinningTransforms: [Float],
        translation: [Float]
    ) throws
    {
        let parameterGroups: [(name: String, values: [Float], expectedCount: Int)] = [
            ("betas", betas, Self.betaCount),
            ("pose feature", poseFeature, Self.poseFeatureCount),
            ("skinning transforms", skinningTransforms, Self.skinningTransformCount),
            ("translation", translation, Self.translationCount),
        ]
        for parameterGroup in parameterGroups
        {
            if parameterGroup.values.count != parameterGroup.expectedCount
            {
                throw CoMotionMeshParametersError.invalidCount(
                    name: parameterGroup.name,
                    expected: parameterGroup.expectedCount,
                    actual: parameterGroup.values.count
                )
            }
            if parameterGroup.values.contains(where: { $0.isFinite == false })
            {
                throw CoMotionMeshParametersError.nonFiniteValue(name: parameterGroup.name)
            }
        }

        self.betas = betas
        self.poseFeature = poseFeature
        self.skinningTransforms = skinningTransforms
        self.translation = translation
    }
}
