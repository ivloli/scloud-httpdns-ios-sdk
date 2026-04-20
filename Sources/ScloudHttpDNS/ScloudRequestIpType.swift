import Foundation

enum ScloudRequestIpType: String, CaseIterable {
    case v4
    case v6
    case both
    case auto

    var queryValue: String {
        switch self {
        case .v4:
            return "4"
        case .v6:
            return "6"
        case .both, .auto:
            return "4,6"
        }
    }
}
