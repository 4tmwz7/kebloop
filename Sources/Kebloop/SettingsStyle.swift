import AppKit
import SwiftUI

struct SettingsCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            configuration.label
                .font(.headline)
                .foregroundStyle(.primary)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
        }
    }
}

