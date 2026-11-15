import BodyMeshProviderCore
import Fabric
import Foundation

struct BodyMeshFrameSelection: Equatable
{
    let frameIndex: Int
    private let confidenceThreshold: Float
    private let maximumBodyCount: Int

    init(node: Node, graphTime: TimeInterval, archive: CoMotionArchiveReader)
    {
        self.init(node: node, frameIndex: Self.resolveFrameIndex(node: node, graphTime: graphTime, archive: archive))
    }

    init(node: Node, frameIndex: Int)
    {
        self.frameIndex = frameIndex
        let inputConfidence: ParameterPort<Float> = node.port(named: "inputConfidence")
        let inputMaximumBodies: ParameterPort<Int> = node.port(named: "inputMaximumBodies")
        let confidence = inputConfidence.value ?? 0.2
        confidenceThreshold = confidence.isFinite ? min(max(confidence, 0.05), 1) : 0.2
        maximumBodyCount = min(max(inputMaximumBodies.value ?? 1, 1), CoMotionArchiveFormat.maximumPeoplePerFrame)
    }

    static func resolveFrameIndex(node: Node, graphTime: TimeInterval, archive: CoMotionArchiveReader) -> Int
    {
        let inputTime: ParameterPort<Float> = node.port(named: "inputTime")
        let inputLoop: ParameterPort<Bool> = node.port(named: "inputLoop")
        let inputRate: ParameterPort<Float> = node.port(named: "inputPlaybackRate")
        let time: TimeInterval
        if inputTime.connectedOutlets.isEmpty
        {
            time = graphTime * TimeInterval(inputRate.value ?? 1)
        }
        else
        {
            time = TimeInterval(inputTime.value ?? 0)
        }
        return archive.frameIndex(time: time, loop: inputLoop.value ?? true)
    }

    func select(_ people: [CoMotionFramePerson]) -> [CoMotionFramePerson]
    {
        people.enumerated()
            .filter { $0.element.confidence > confidenceThreshold }
            .sorted { first, second in
                if first.element.confidence == second.element.confidence { return first.offset < second.offset }
                return first.element.confidence > second.element.confidence
            }
            .prefix(maximumBodyCount)
            .map(\.element)
    }
}
