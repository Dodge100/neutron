import SwiftUI
import QuickLookThumbnailing

// MARK: - Thumbnail Icon (shared component for async QuickLook previews)

struct ThumbnailIcon: View {
    let file: FileItem
    let size: CGFloat
    var hiddenOpacity: CGFloat = 1
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? file.nsImage)
            .resizable()
            .frame(width: size, height: size)
            .opacity(hiddenOpacity)
            .task(id: file.path) {
                FileIconCache.shared.loadThumbnail(for: file.path, size: size) {
                    thumbnail = FileIconCache.shared.icon(for: file.path)
                }
            }
    }
}

// MARK: - Icon View (exact Finder-style)

struct FileIconGridView<ContextMenu: View>: View {
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    let iconSize: CGFloat
    var onSelect: (FileItem, Bool) -> Void
    var onOpen: (FileItem) -> Void
    let currentPath: URL
    let gitStatuses: [String: GitFileStatus]
    var contextMenuForFile: (FileItem) -> ContextMenu

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72, maximum: 120), spacing: 2)],
                spacing: 2
            ) {
                ForEach(files) { file in
                    FinderIconCell(
                        file: file,
                        iconSize: iconSize,
                        isSelected: selectedFiles.contains(file.path)
                    )
                    .onTapGesture(count: 2) { onOpen(file) }
                    .onTapGesture(count: 1) { onSelect(file, false) }
                    .contextMenu { contextMenuForFile(file) }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct FinderIconCell: View {
    let file: FileItem
    let iconSize: CGFloat
    let isSelected: Bool

    private var cellHeight: CGFloat {
        iconSize + 56 // icon + spacing + 2 lines of text + padding
    }

    var body: some View {
        VStack(spacing: 2) {
            ThumbnailIcon(file: file, size: iconSize, hiddenOpacity: file.isHidden ? 0.45 : 1)

            Text(file.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .top)
                .opacity(file.isHidden ? 0.45 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: max(iconSize + 24, 72), height: cellHeight)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
