import Foundation
import simd

public enum BodyMeshIntrinsicCameraProjectionError: Error, Equatable
{
    case invalidSourceSize(SIMD2<Float>)
    case invalidViewportAspectRatio(Float)
}

/// Reproduces the intrinsic body-mesh camera projection used by the generator app.
public struct BodyMeshIntrinsicCameraProjection: Equatable, Sendable
{
    public let sourceSize: SIMD2<Float>

    public init(sourceSize: SIMD2<Float>) throws
    {
        guard sourceSize.x.isFinite,
              sourceSize.y.isFinite,
              sourceSize.x > 0,
              sourceSize.y > 0
        else
        {
            throw BodyMeshIntrinsicCameraProjectionError.invalidSourceSize(sourceSize)
        }

        self.sourceSize = sourceSize
    }

    public var focalLength: Float
    {
        2 * max(sourceSize.x, sourceSize.y)
    }

    public func clipSpaceScale(viewportAspectRatio: Float) throws -> SIMD2<Float>
    {
        guard viewportAspectRatio.isFinite, viewportAspectRatio > 0 else
        {
            throw BodyMeshIntrinsicCameraProjectionError.invalidViewportAspectRatio(
                viewportAspectRatio
            )
        }

        let sourceAspectRatio = sourceSize.x / sourceSize.y
        let aspectFitScale = SIMD2<Float>(
            min(1, sourceAspectRatio / viewportAspectRatio),
            min(1, viewportAspectRatio / sourceAspectRatio)
        )

        return SIMD2<Float>(
            2 * focalLength / sourceSize.x * aspectFitScale.x,
            2 * focalLength / sourceSize.y * aspectFitScale.y
        )
    }

    public func verticalFieldOfView(viewportAspectRatio: Float) throws -> Float
    {
        let verticalScale = try clipSpaceScale(
            viewportAspectRatio: viewportAspectRatio
        ).y
        return 2 * atan(1 / verticalScale) * 180 / .pi
    }
}
