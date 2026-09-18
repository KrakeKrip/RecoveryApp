import Foundation

enum RecoveryFeature: String, CaseIterable, Identifiable {
    case videoRepair
    case deletedFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoRepair: "Повреждённые видео"
        case .deletedFiles: "Удалённые файлы"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedFeature: RecoveryFeature?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        switch environment["RECOVERYAPP_TEST_SCREEN"] {
        case "video":
            selectedFeature = .videoRepair
        case "deleted":
            selectedFeature = .deletedFiles
        default:
            break
        }
    }
}
