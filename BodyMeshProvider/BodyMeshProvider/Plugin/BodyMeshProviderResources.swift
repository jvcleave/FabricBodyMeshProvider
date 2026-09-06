import BodyMeshProviderCore
import Foundation

enum BodyMeshProviderResourceError: LocalizedError
{
    case missingMeshConstants

    var errorDescription: String?
    {
        switch self
        {
            case .missingMeshConstants:
                return "CoMotionMeshConstants.bin is missing from the Body Mesh Provider plug-in."
        }
    }
}

enum BodyMeshProviderResources
{
    private static let meshReconstructorResult: Result<CoMotionMeshReconstructor, Error> = Result
    {
        guard let constantsURL = Bundle(for: BodyMeshProviderPlugin.self).url(
            forResource: "CoMotionMeshConstants",
            withExtension: "bin"
        )
        else
        {
            throw BodyMeshProviderResourceError.missingMeshConstants
        }

        let constantsData = try Data(contentsOf: constantsURL, options: .mappedIfSafe)
        return try CoMotionMeshReconstructor(constantsData: constantsData)
    }

    static func meshReconstructor() throws -> CoMotionMeshReconstructor
    {
        try meshReconstructorResult.get()
    }
}
