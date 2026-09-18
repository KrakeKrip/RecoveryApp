import AppKit
import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            PrivacySettingsView()
                .tabItem { Label("Конфиденциальность", systemImage: "hand.raised") }
            AboutSettingsView()
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 420)
    }
}

struct PrivacySettingsView: View {
    var body: some View {
        Form {
            Section("Конфиденциальность") {
                Label("Сетевой обмен отключён", systemImage: "network.slash")
                    .foregroundStyle(.green)
                Text("В этой версии RecoveryApp не отправляет телеметрию, журналы, имена, пути или содержимое файлов. Все операции выполняются локально на этом Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Сеть и необязательная телеметрия запланированы на будущий этап после готовности локального восстановления. Они потребуют отдельного согласия и не будут передавать содержимое файлов.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsView: View {
    private var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "RecoveryApp", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Версия \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RecoveryApp").font(.title2.bold())
                        Text(version).foregroundStyle(.secondary)
                    }
                }

                Text("Локальное приложение для восстановления повреждённых видео и поиска удалённых фото и видео. Исходный накопитель открывается только для чтения.")

                Divider()
                Text("Лицензии компонентов").font(.headline)
                LicenseRow(name: "RecoveryApp", license: "GNU GPL v2")
                LicenseRow(name: "untrunc и PhotoRec", license: "GNU GPL v2")
                LicenseRow(name: "libjpeg-turbo", license: "BSD-style и IJG")
                LicenseRow(name: "Sleuth Kit: fls, icat, mmls", license: "CPL 1.0 / IBM Public License 1.0")

                Text("Полные тексты лицензий, уведомления и архивы точных исходников включены внутрь приложения. Компоненты Sleuth Kit запускаются как отдельные программы и не линкуются с RecoveryApp.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Copyright © 2026 RecoveryApp contributors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

private struct LicenseRow: View {
    let name: String
    let license: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer()
            Text(license).foregroundStyle(.secondary)
        }
    }
}
