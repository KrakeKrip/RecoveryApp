import SwiftUI

enum OperationResultTone {
    case success
    case warning
    case failure

    var color: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "stop.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}

struct OperationResultCard: View {
    let tone: OperationResultTone
    let title: String
    let message: String
    var path: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: tone.icon)
                .font(.system(size: 34))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.title3.bold())
                Text(message)
                    .foregroundStyle(.secondary)
                if let path {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(tone.color)
                    .controlSize(.large)
            }
        }
        .padding(18)
        .background(tone.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(tone.color.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
