import XCTest
@testable import BodyMeshProviderCore

final class BodyMeshIntrinsicCameraProjectionTests: XCTestCase
{
    func testMatchesSourceAspectProjection() throws
    {
        let projection = try BodyMeshIntrinsicCameraProjection(
            sourceSize: SIMD2<Float>(1920, 1080)
        )

        XCTAssertEqual(projection.focalLength, 3840)
        let scale = try projection.clipSpaceScale(
            viewportAspectRatio: 1920.0 / 1080.0
        )
        XCTAssertEqual(scale.x, 4, accuracy: 0.0001)
        XCTAssertEqual(scale.y, 64.0 / 9.0, accuracy: 0.0001)
    }

    func testAspectFitPreservesVerticalFramingInWiderViewport() throws
    {
        let projection = try BodyMeshIntrinsicCameraProjection(
            sourceSize: SIMD2<Float>(1920, 1080)
        )

        let scale = try projection.clipSpaceScale(viewportAspectRatio: 2)
        XCTAssertEqual(scale.x, 32.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(scale.y, 64.0 / 9.0, accuracy: 0.0001)
    }

    func testAspectFitPreservesHorizontalFramingInTallerViewport() throws
    {
        let projection = try BodyMeshIntrinsicCameraProjection(
            sourceSize: SIMD2<Float>(1920, 1080)
        )

        let scale = try projection.clipSpaceScale(viewportAspectRatio: 1)
        XCTAssertEqual(scale.x, 4, accuracy: 0.0001)
        XCTAssertEqual(scale.y, 4, accuracy: 0.0001)
        XCTAssertEqual(
            try projection.verticalFieldOfView(viewportAspectRatio: 1),
            28.0725,
            accuracy: 0.0001
        )
    }

    func testRejectsInvalidDimensionsAndViewport() throws
    {
        XCTAssertThrowsError(
            try BodyMeshIntrinsicCameraProjection(sourceSize: SIMD2<Float>(0, 1080))
        )

        let projection = try BodyMeshIntrinsicCameraProjection(
            sourceSize: SIMD2<Float>(1920, 1080)
        )
        XCTAssertThrowsError(
            try projection.clipSpaceScale(viewportAspectRatio: 0)
        )
    }
}
