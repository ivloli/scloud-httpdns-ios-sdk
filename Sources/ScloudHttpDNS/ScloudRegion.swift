import Foundation

enum ScloudRegion: String, CaseIterable {
    case `default` = "default"
    case cn = "cn"
    case os = "os"
    case global = "global"

    var serverValue: String {
        switch self {
        case .default:
            return "global"
        default:
            return rawValue
        }
    }
}
