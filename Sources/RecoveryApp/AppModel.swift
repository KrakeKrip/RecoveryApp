import Foundation

enum RecoveryFeature: String, CaseIterable, Identifiable, Hashable {
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

    // One source of truth for selection and the native Back button. Use the
    // value/path navigation API rather than optional-item presentation on Sonoma.
    var navigationPath: [RecoveryFeature] {
        get { selectedFeature.map { [$0] } ?? [] }
        set { selectedFeature = newValue.last }
    }

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
