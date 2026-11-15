import Fabric

public struct CharacterInspectorSettings: NodeSettings
{
    public struct Target: Codable, Equatable, Identifiable, Sendable
    {
        public enum Kind: String, Codable, Sendable
        {
            case meshVisibility
            case materialVisibility
            case material
        }

        public let kind: Kind
        public let path: String
        public let label: String

        public init(kind: Kind, path: String, label: String)
        {
            self.kind = kind
            self.path = path
            self.label = label
        }

        public var id: String { "\(kind.rawValue):\(path)" }

        public var portName: String
        {
            switch kind
            {
                case .meshVisibility: return "\(label) Visible"
                case .materialVisibility: return "\(label) Material Visible"
                case .material: return "\(label) Material"
            }
        }
    }

    public let targets: [Target]

    public init(targets: [Target])
    {
        var seen = Set<String>()
        self.targets = targets.filter { seen.insert($0.id).inserted }
    }

    private enum CodingKeys: String, CodingKey
    {
        case targets = "characterInspectorTargets"
    }

    public init(from decoder: Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(targets: try container.decodeIfPresent([Target].self, forKey: .targets) ?? [])
    }
}
