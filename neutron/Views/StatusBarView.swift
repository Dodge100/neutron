import SwiftUI

struct StatusBarView: View {
    let totalCount: Int
    let selectedCount: Int
    let selectedSize: Int64

    var body: some View {
        Text(statusText)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }

    private var statusText: String {
        if selectedCount > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let sizeStr = formatter.string(fromByteCount: selectedSize)
            return "\(selectedCount) of \(totalCount) selected, \(sizeStr)"
        }
        return "\(totalCount) items"
    }
}
