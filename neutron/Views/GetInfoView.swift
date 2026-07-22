import SwiftUI

struct GetInfoView: View {
    let info: FileInfo
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: info.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                Text(info.name)
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Divider()

            InfoRow(label: "Kind", value: info.kind)
            InfoRow(label: "Size", value: {
                let f = ByteCountFormatter()
                f.countStyle = .file
                return f.string(fromByteCount: info.size)
            }())
            InfoRow(label: "Location", value: info.path)
            InfoRow(label: "Created", value: info.created.formatted())
            InfoRow(label: "Modified", value: info.modified.formatted())
            InfoRow(label: "Permissions", value: info.permissions)
            if let count = info.itemCount {
                InfoRow(label: "Items", value: "\(count)")
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
