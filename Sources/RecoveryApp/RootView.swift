import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [RecoveryPalette.plum.opacity(0.20), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("RecoveryApp")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("Что нужно восстановить?")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        FeatureCard(
                            icon: "video.badge.ellipsis",
                            title: "Повреждённые видео",
                            description: "Исправление видео по рабочему примеру с того же устройства.",
                            status: "Исправить видео"
                        ) {
                            model.selectedFeature = .videoRepair
                        }

                        FeatureCard(
                            icon: "externaldrive.badge.questionmark",
                            title: "Удалённые файлы",
                            description: "Поиск на USB, SD-картах и внешних накопителях только для чтения.",
                            status: "Найти файлы"
                        ) {
                            model.selectedFeature = .deletedFiles
                        }
                    }

                    SafetyNotice()
                }
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        .tint(RecoveryPalette.plum)
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let status: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 27))
                        .foregroundStyle(RecoveryPalette.lavender)
                        .frame(width: 58, height: 58)
                        .background(RecoveryPalette.plum.opacity(0.16), in: RoundedRectangle(cornerRadius: 17))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.title2.bold())
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RecoveryPalette.lavender)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 224)
            .recoveryPanel()
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
        .recoveryPanel()
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
