import SwiftUI
import QuickLookThumbnailing

// MARK: - Column View (Finder-style column browser)

struct FileColumnBrowserView<ContextMenu: View>: View {
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    @Binding var currentPath: URL
    var onSelect: (FileItem, Bool) -> Void
    var onOpen: (FileItem) -> Void
    let currentDirectoryFiles: [FileItem]
    let gitStatuses: [String: GitFileStatus]
    var contextMenuForFile: (FileItem) -> ContextMenu

    @State private var columnPath: [URL] = []
    @State private var columnFiles: [URL: [FileItem]] = [:]
    @State private var loadTasks: [URL: Task<Void, Never>] = [:]

    var body: some View {
        HSplitView {
            FinderColumn(
                title: currentPath.lastPathComponent,
                files: currentDirectoryFiles,
                selectedFiles: $selectedFiles,
                onSelect: { handleSelect($0, in: currentPath) },
                onOpen: { file in
                    if file.isDirectory { navigateInto(file.path, from: currentPath) }
                    else { onOpen(file) }
                },
                contextMenuForFile: contextMenuForFile
            )

            ForEach(Array(columnPath.enumerated()), id: \.offset) { _, path in
                FinderColumn(
                    title: path.lastPathComponent,
                    files: columnFiles[path] ?? [],
                    selectedFiles: $selectedFiles,
                    onSelect: { handleSelect($0, in: path) },
                    onOpen: { file in
                        if file.isDirectory { navigateInto(file.path, from: path) }
                        else { onOpen(file) }
                    },
                    contextMenuForFile: contextMenuForFile
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { columnPath = []; columnFiles = [:] }
    }

    // MARK: - Navigation

    private func handleSelect(_ file: FileItem, in path: URL) {
        onSelect(file, NSEvent.modifierFlags.contains(.command))
    }

    private func navigateInto(_ folderURL: URL, from parentPath: URL) {
        if columnPath.last == folderURL { return }
        if let parentIndex = columnPath.firstIndex(of: parentPath) {
            columnPath = Array(columnPath.prefix(parentIndex + 1))
        }
        columnPath.append(folderURL)
        if columnPath.count > 5 { columnPath = Array(columnPath.suffix(5)) }
        loadChildren(for: folderURL)
        currentPath = folderURL
    }

    private func loadChildren(for directoryURL: URL) {
        guard columnFiles[directoryURL] == nil, directoryURL.isFileURL else { return }
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
                await MainActor.run { columnFiles[directoryURL] = sorted }
            } catch {
                await MainActor.run { columnFiles[directoryURL] = [] }
            }
        }
        loadTasks[directoryURL] = task
    }
}

// MARK: - Single Finder Column

private struct FinderColumn<ContextMenu: View>: View {
    let title: String
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    var onSelect: (FileItem) -> Void
    var onOpen: (FileItem) -> Void
    var contextMenuForFile: (FileItem) -> ContextMenu

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Native list
            List(selection: $selectedFiles) {
                ForEach(files) { file in
                    FinderColumnRow(file: file)
                        .tag(file.id)
                        .onTapGesture(count: 2) { onOpen(file) }
                        .onTapGesture(count: 1) { onSelect(file) }
                        .contextMenu { contextMenuForFile(file) }
                }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 180, idealWidth: 220)
    }
}

// MARK: - Column Row

private struct FinderColumnRow: View {
    let file: FileItem

    var body: some View {
        HStack(spacing: 6) {
            ThumbnailIcon(file: file, size: 16, hiddenOpacity: file.isHidden ? 0.45 : 1)

            Text(file.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .opacity(file.isHidden ? 0.45 : 1)

            Spacer()

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 20)
    }
}
