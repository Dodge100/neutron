import SwiftUI

struct StatusBarView: View {
    let totalCount: Int
    let selectedCount: Int

    var body: some View {
        HStack(spacing: 6) {
            if selectedCount > 0 {
                Text("\(selectedCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)

                Text("/ \(totalCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(totalCount) \(totalCount == 1 ? "item" : "items")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        StatusBarView(totalCount: 128, selectedCount: 0)
        StatusBarView(totalCount: 128, selectedCount: 5)
    }
    .frame(width: 300)
}
