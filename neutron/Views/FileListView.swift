import SwiftUI
import QuickLookThumbnailing

// MARK: - List View (Finder-style list with disclosure triangles)

struct FileListView<ContextMenu: View>: View {
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    var onSelect: (FileItem, Bool) -> Void
    var onOpen: (FileItem) -> Void
    let currentPath: URL
    let gitStatuses: [String: GitFileStatus]
    @Binding var sortColumn: FileBrowserView.SortColumn
    @Binding var sortAscending: Bool
    var contextMenuForFile: (FileItem) -> ContextMenu

    @State private var expandedFolders: Set<URL> = []
    @State private var folderContents: [URL: [FileItem]] = [:]
    @State private var loadTasks: [URL: Task<Void, Never>] = [:]
    @State private var sortOrder = [KeyPathComparator(\FlatRow.name, order: .forward)]

    var body: some View {
        Table(flatRows, selection: $selectedFiles, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 0) {
                    Spacer().frame(width: CGFloat(row.depth) * 16)
                    if row.file.isDirectory {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                            .onTapGesture { toggleExpand(row.file.path) }
                    } else {
                        Spacer().frame(width: 12)
                    }
                    ThumbnailIcon(file: row.file, size: 16, hiddenOpacity: row.file.isHidden ? 0.45 : 1)
                        .padding(.trailing, 6)
                    Text(row.file.name)
                        .lineLimit(1)
                        .opacity(row.file.isHidden ? 0.45 : 1)
                }
            }
            .width(min: 200, ideal: 300)

            TableColumn("Date Modified", value: \.modifiedDate) { row in
                Text(row.file.formattedDate)
            }
            .width(140)

            TableColumn("Size", value: \.sizeBytes) { row in
                Text(row.file.formattedSize)
            }
            .width(90)

            TableColumn("Kind", value: \.kindString) { row in
                Text(row.file.kindString)
            }
            .width(130)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            if let id = ids.first, let file = files.first(where: { $0.id == id }) {
                contextMenuForFile(file)
            }
        } primaryAction: { ids in
            if let id = ids.first, let file = files.first(where: { $0.id == id }) {
                onOpen(file)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Flat Rows

    private var flatRows: [FlatRow] {
        var rows: [FlatRow] = []
        buildFlatList(files, depth: 0, into: &rows)
        return rows
    }

    private func buildFlatList(_ items: [FileItem], depth: Int, into rows: inout [FlatRow]) {
        for item in items {
            let expanded = item.isDirectory && expandedFolders.contains(item.path)
            rows.append(FlatRow(id: item.path, file: item, depth: depth, isExpanded: expanded))
            if expanded, let children = folderContents[item.path] {
                buildFlatList(children, depth: depth + 1, into: &rows)
            }
        }
    }

    // MARK: - Expand

    private func toggleExpand(_ folderURL: URL) {
        if expandedFolders.contains(folderURL) {
            expandedFolders.remove(folderURL)
        } else {
            expandedFolders.insert(folderURL)
            loadChildren(for: folderURL)
        }
    }

    private func loadChildren(for directoryURL: URL) {
        guard folderContents[directoryURL] == nil, directoryURL.isFileURL else { return }
        loadTasks[directoryURL]?.cancel()

        let task = Task.detached(priority: .userInitiated) {
            do {
                let fm = FileManager.default
                let contents = try fm.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .fileSizeKey,
                        .contentModificationDateKey, .creationDateKey, .tagNamesKey,
                    ],
                    options: [.skipsHiddenFiles]
                )
                let items = contents.compactMap { FileItem.fromURL($0) }
                let sorted = items.sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCompare(b.name) == .orderedAscending
                }
                await MainActor.run { folderContents[directoryURL] = sorted }
            } catch {
                await MainActor.run { folderContents[directoryURL] = [] }
            }
        }
        loadTasks[directoryURL] = task
    }
}

// MARK: - Flat Row (with sortable keypaths)

private struct FlatRow: Identifiable {
    let id: URL
    let file: FileItem
    let depth: Int
    let isExpanded: Bool

    var name: String { file.name }
    var modifiedDate: Date { file.modified }
    var sizeBytes: Int64 { file.size }
    var kindString: String { file.kindString }
}
