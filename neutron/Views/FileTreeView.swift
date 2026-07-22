import SwiftUI

// MARK: - Tree View (Finder-style outline)

struct FileTreeView<ContextMenu: View>: View {
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    var onSelect: (FileItem, Bool) -> Void
    var onOpen: (FileItem) -> Void
    let currentPath: URL
    let gitStatuses: [String: GitFileStatus]
    var contextMenuForFile: (FileItem) -> ContextMenu

    @State private var expandedFolders: Set<URL> = []
    @State private var folderContents: [URL: [FileItem]] = [:]
    @State private var loadTasks: [URL: Task<Void, Never>] = [:]

    var body: some View {
        List(selection: $selectedFiles) {
            ForEach(files) { file in
                FinderTreeNode(
                    file: file,
                    expandedFolders: $expandedFolders,
                    folderContents: folderContents,
                    onSelect: onSelect,
                    onOpen: onOpen,
                    onToggleExpand: toggleExpand,
                    contextMenuForFile: contextMenuForFile
                )
            }
        }
        .listStyle(.sidebar)
        .background(Color(nsColor: .textBackgroundColor))
    }

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

// MARK: - Tree Node (uses DisclosureGroup for native expand/collapse)

private struct FinderTreeNode<ContextMenu: View>: View {
    let file: FileItem
    @Binding var expandedFolders: Set<URL>
    let folderContents: [URL: [FileItem]]
    var onSelect: (FileItem, Bool) -> Void
    var onOpen: (FileItem) -> Void
    var onToggleExpand: (URL) -> Void
    var contextMenuForFile: (FileItem) -> ContextMenu

    private var isExpanded: Bool { expandedFolders.contains(file.path) }
    private var children: [FileItem] { folderContents[file.path] ?? [] }

    var body: some View {
        if file.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { _ in onToggleExpand(file.path) }
            )) {
                ForEach(children) { child in
                    FinderTreeNode(
                        file: child,
                        expandedFolders: $expandedFolders,
                        folderContents: folderContents,
                        onSelect: onSelect,
                        onOpen: onOpen,
                        onToggleExpand: onToggleExpand,
                        contextMenuForFile: contextMenuForFile
                    )
                }
            } label: {
                Label {
                    Text(file.name).lineLimit(1)
                } icon: {
                    Image(nsImage: file.nsImage)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .padding(.vertical, 4)
            }
            .listRowSeparator(.hidden)
            .contextMenu { contextMenuForFile(file) }
        } else {
            Label {
                Text(file.name).lineLimit(1)
            } icon: {
                Image(nsImage: file.nsImage)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            .listRowSeparator(.hidden)
            .contextMenu { contextMenuForFile(file) }
        }
    }
}
