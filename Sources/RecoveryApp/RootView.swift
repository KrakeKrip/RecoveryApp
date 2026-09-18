import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RecoveryApp")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Безопасное восстановление данных на macOS")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 18) {
                        FeatureCard(
                            icon: "video.badge.ellipsis",
                            title: "Повреждённые видео",
                            description: "Исправление видео по рабочему примеру с того же устройства.",
                            status: "Встроенный untrunc готов",
                            tint: .blue
                        ) {
                            model.selectedFeature = .videoRepair
                        }

                        FeatureCard(
                            icon: "externaldrive.badge.questionmark",
                            title: "Удалённые файлы",
                            description: "Поиск на USB, SD-картах и внешних накопителях только для чтения.",
                            status: "Накопители и PhotoRec готовы",
                            tint: .orange
                        ) {
                            model.selectedFeature = .deletedFiles
                        }
                    }

                    SafetyNotice()
                    Spacer(minLength: 0)
                }
                .padding(36)
            }
            .navigationDestination(item: $model.selectedFeature) { feature in
                if feature == .videoRepair {
                    VideoRepairView()
                } else {
                    DeletedFilesView()
                }
            }
        }
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let status: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title2.bold())
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Label(status, systemImage: "hammer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открыть раздел")
    }
}

private struct SafetyNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Исходные данные не изменяются")
                    .font(.headline)
                Text("RecoveryApp будет читать исходные файлы и накопители без записи, а результат сохранять отдельно.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct FeaturePlaceholderView: View {
    let feature: RecoveryFeature

    var body: some View {
        ContentUnavailableView {
            Label(feature.title, systemImage: feature == .videoRepair ? "video" : "externaldrive")
        } description: {
            Text("Раздел создан, рабочий процесс будет подключён на следующем этапе.")
        }
        .navigationTitle(feature.title)
    }
}
