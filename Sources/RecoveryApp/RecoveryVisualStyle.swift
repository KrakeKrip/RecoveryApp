import SwiftUI

enum RecoveryPalette {
    static let plum = Color(red: 0.54, green: 0.39, blue: 0.70)
    static let lavender = Color(red: 0.76, green: 0.67, blue: 0.91)
}

struct RecoveryPageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 17) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(RecoveryPalette.lavender)
                .frame(width: 62, height: 62)
                .background(RecoveryPalette.plum.opacity(0.17), in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecoveryStepHeading: View {
    let number: Int
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Text(String(number))
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(RecoveryPalette.plum, in: Circle())
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(RecoveryPalette.lavender)
                .accessibilityHidden(true)
        }
    }
}

private struct RecoveryPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(RecoveryPalette.lavender.opacity(0.18), lineWidth: 1)
            }
    }
}

extension View {
    func recoveryPanel() -> some View {
        modifier(RecoveryPanelStyle())
    }
}
