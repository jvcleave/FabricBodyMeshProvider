import Fabric
import Satin
import simd

enum BodyMeshPlaybackPorts
{
    static func inputs() -> [(name: String, port: Fabric.Port)]
    {
        [
            (
                "inputTime",
                ParameterPort(
                    parameter: FloatParameter(
                        "Time",
                        0,
                        .inputfield,
                        "Playback time in seconds; graph time is used when this inlet is unconnected"
                    )
                )
            ),
            (
                "inputLoop",
                ParameterPort(
                    parameter: BoolParameter(
                        "Loop",
                        true,
                        .toggle,
                        "Wrap playback at the end of the asset"
                    )
                )
            ),
            (
                "inputPlaybackRate",
                ParameterPort(
                    parameter: FloatParameter(
                        "Playback Rate",
                        1,
                        .inputfield,
                        "Graph-time playback multiplier; ignored when Time is connected"
                    )
                )
            ),
            (
                "inputConfidence",
                ParameterPort(
                    parameter: FloatParameter(
                        "Confidence",
                        0.2,
                        0.05,
                        1,
                        .slider,
                        "Minimum confidence required to output a detected body"
                    )
                )
            ),
            (
                "inputMaximumBodies",
                ParameterPort(
                    parameter: IntParameter(
                        "Maximum Bodies",
                        1,
                        1,
                        8,
                        .inputfield,
                        "Maximum number of highest-confidence bodies to output"
                    )
                )
            ),
        ]
    }

    static func outputs() -> [(name: String, port: Fabric.Port)]
    {
        [
            (
                "outputDetectedBodies",
                NodePort<Int>(
                    name: "Detected Bodies",
                    kind: .Outlet,
                    description: "Number of bodies stored in the current frame before filtering"
                )
            ),
            (
                "outputBodies",
                NodePort<Int>(
                    name: "Output Bodies",
                    kind: .Outlet,
                    description: "Number of bodies included in the geometry after filtering"
                )
            ),
            (
                "outputCurrentFrame",
                NodePort<Int>(
                    name: "Current Frame",
                    kind: .Outlet,
                    description: "Zero-based archive frame currently selected"
                )
            ),
            (
                "outputFrameRate",
                NodePort<Float>(
                    name: "Frame Rate",
                    kind: .Outlet,
                    description: "Encoded frame rate of the selected asset"
                )
            ),
            (
                "outputFrameCount",
                NodePort<Int>(
                    name: "Frame Count",
                    kind: .Outlet,
                    description: "Total number of archive frames"
                )
            ),
            (
                "outputDuration",
                NodePort<Float>(
                    name: "Duration",
                    kind: .Outlet,
                    description: "Asset playback duration in seconds"
                )
            ),
            (
                "outputFrameAvailable",
                NodePort<Bool>(
                    name: "Frame Available",
                    kind: .Outlet,
                    description: "True when at least one body passed filtering in the current frame"
                )
            ),
            (
                "outputSourceSize",
                NodePort<simd_float2>(
                    name: "Source Size",
                    kind: .Outlet,
                    description: "Encoded source width and height"
                )
            ),
        ]
    }
}
