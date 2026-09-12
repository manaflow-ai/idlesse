import Foundation

enum IdlesseScalingMode: String, CaseIterable, Codable {
    case fit
    case fill
    case actual

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .actual: return "Actual Size"
        }
    }
}
