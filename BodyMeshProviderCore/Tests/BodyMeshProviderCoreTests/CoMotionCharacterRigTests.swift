import BodyMeshProviderCore
import simd
import XCTest

final class CoMotionCharacterRigTests: XCTestCase
{
    func testRegistersPelvisAndCarriesUnmappedChildThroughCameraRotation() throws
    {
        var pelvis = matrix_identity_float4x4
        pelvis.columns.3.y = 1
        var child = matrix_identity_float4x4
        child.columns.3.x = 1
        let rig = try CoMotionCharacterRig(joints: [
            .init(parent: nil, source: 0, localReference: pelvis, inverseBind: pelvis.inverse),
            .init(parent: 0, source: -1, localReference: child, inverseBind: (pelvis * child).inverse),
        ])
        let rootTransform: [Float] = [
            0, 0, 1, 3,
            0, 1, 0, 1,
            -1, 0, 0, 4,
            0, 0, 0, 1,
        ]
        let identityTransform: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        let transforms = rootTransform + (1 ..< 24).flatMap { _ in identityTransform }
        let palette = try rig.skinningMatrices(transforms)

        let movedPelvis = palette[0] * pelvis.columns.3
        let movedChild = palette[1] * (pelvis * child).columns.3
        XCTAssertLessThan(simd_distance(movedPelvis, SIMD4(3, -0.8, -4, 1)), 0.00001)
        XCTAssertLessThan(simd_distance(movedChild - movedPelvis, SIMD4(0, 0, 1, 0)), 0.00001)
    }
}
