import SwiftUI

struct LogPanel: View {
    @Binding var isExpanded: Bool
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Подробный лог")
                        .font(.headline)
                    Spacer()
                    Text(isExpanded ? "Скрыть" : "Показать")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Открыт" : "Закрыт")

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Технический журнал операции")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(text.isEmpty ? "После запуска здесь появятся этапы работы и возможные ошибки." : text)
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .frame(minHeight: 125, maxHeight: 190)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
