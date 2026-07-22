import SwiftUI
import AppKit
import Combine
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

private extension Color {
    static var neutronSelectionAccent: Color {
        Color(nsColor: .controlAccentColor)
    }
}

private enum FileMoveNotificationUserInfoKey {
    static let affectedDirectories = "affectedDirectories"
}

// MARK: - FileBrowserView

struct FileBrowserView: View {
    enum ExternalCommand: Equatable {
        case duplicate
        case copy
        case cut
        case paste
        case selectAll
        case quickLook
        case getInfo
        case rename
        case refresh
        case openInTerminal
        case openPathPrompt
    }

    @Binding var currentPath: URL
    @Binding var viewMode: ViewMode
    @Binding var showHiddenFiles: Bool
    var searchText: String = ""
    var showsPathBar: Bool = true
    var showsStatusBar: Bool = true
    var externalCommand: ExternalCommand? = nil
    var onPreviewSelectionChange: ((FilePreviewItem?) -> Void)? = nil
    var onInteraction: (() -> Void)? = nil

    @EnvironmentObject private var fileOps: FileOperations
    @AppStorage("iconSize") private var iconSize: Double = 48
    @AppStorage("showSizeColumn") private var showSizeColumn = true
    @AppStorage("showDateColumn") private var showDateColumn = true
    @AppStorage("showKindColumn") private var showKindColumn = true
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true
    @State private var files: [FileItem] = []
    @State private var selectedFiles: Set<URL> = []
    @State private var sortColumn: SortColumn = .name
    @State private var sortAscending: Bool = true
    @State private var loadError: String?
    @State private var showCopiedPath = false
    @State private var pendingTrashURLs: [URL] = []
    @State private var showTrashConfirmation = false

    // Rename
    @State private var renamingFile: URL?
    @State private var renameText: String = ""

    // Get Info
    @State private var showGetInfo: Bool = false
    @State private var getInfoTarget: FileInfo?

    // Git
    @State private var gitStatuses: [String: GitFileStatus] = [:]
    @State private var commandNonce = UUID()
    @State private var lastClickedURL: URL?
    @State private var lastClickTimestamp: TimeInterval = 0
    @State private var previewRequestID = UUID()
    @State private var showOpenPathPrompt = false
    @State private var openPathPromptText = ""

    enum SortColumn {
        case name, size, modified, kind
    }

    enum ViewMode: String, CaseIterable {
        case icon = "Icon"
        case list = "List"
        case column = "Column"
        case tree = "Tree"

        var icon: String {
            switch self {
            case .icon: return "square.grid.2x2"
            case .list: return "list.bullet"
            case .column: return "rectangle.split.3x1"
            case .tree: return "folder"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = loadError {
                ContentUnavailableView {
                    Label("Cannot Access Folder", systemImage: "lock.shield")
                } description: {
                    Text(error)
                } actions: {
                    Button("Open in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: currentPath.path)
                    }
                    Button("Go Home") {
                        currentPath = FileManager.default.homeDirectoryForCurrentUser
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                EmptyView()
            }

            // File content area
            fileContentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if showsPathBar || showsStatusBar {
                Divider()

                HStack(spacing: 0) {
                    if showsPathBar {
                        HStack(spacing: 6) {
                            PathBarView(currentPath: $currentPath)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(currentPath.path, forType: .string)
                                showCopiedPath = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                                    showCopiedPath = false
                                }
                            } label: {
                                Image(systemName: showCopiedPath ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(showCopiedPath ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy Path")
                            .padding(.trailing, 6)
                        }
                    }

                    if showsPathBar && showsStatusBar {
                        Spacer()
                    }

                    if showsStatusBar {
                        StatusBarView(
                            totalCount: filteredFiles.count,
                            selectedCount: selectedFiles.count,
                            selectedSize: selectedSize
                        )
                        .padding(.trailing, 4)
                    }
                }
                .frame(height: 20)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu {
            creationContextMenuItems()
            Divider()
            Button("Paste") {
                fileOps.pasteFiles(to: currentPath)
                loadFiles()
            }
            .disabled(fileOps.clipboardURLs.isEmpty)
            Button("Refresh") { loadFiles() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls, to: currentPath)
        }
        .onAppear {
            loadFiles()
            publishPreviewSelection()
        }
        .onDisappear {
            onPreviewSelectionChange?(nil)
        }
        .onChange(of: currentPath) { _, _ in
            loadFiles()
            publishPreviewSelection()
        }
        .onChange(of: searchText) { _, _ in loadFiles() }
        .onChange(of: showHiddenFiles) { _, _ in loadFiles() }
        .onChange(of: sortColumn) { _, _ in files = sortFiles(files) }
        .onChange(of: sortAscending) { _, _ in files = sortFiles(files) }
        .onChange(of: selectedFiles) { _, _ in
            publishPreviewSelection()
        }
        .onChange(of: files) { _, _ in
            let stillExists = Set(files.map(\.path))
            selectedFiles = selectedFiles.intersection(stillExists)
            publishPreviewSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trashSelectedFiles)) { _ in
            handleDeleteRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shareSelectedFiles)) { _ in
            let urls = Array(selectedFiles)
            guard !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                let rect = CGRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 50, width: 1, height: 1)
                picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedItem)) { _ in
            if let url = selectedFiles.first, let file = files.first(where: { $0.path == url }) {
                handleOpen(file)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileSystemEntriesMoved)) { notification in
            guard let affectedDirectories = notification.userInfo?[FileMoveNotificationUserInfoKey.affectedDirectories] as? [String] else { return }
            let currentDirectory = currentPath.standardizedFileURL.path
            if affectedDirectories.contains(currentDirectory) {
                loadFiles()
            }
        }
        .sheet(isPresented: $showGetInfo) {
            if let info = getInfoTarget {
                GetInfoView(info: info, isPresented: $showGetInfo)
            }
        }
        .sheet(isPresented: $showOpenPathPrompt) {
            PathEditorSheet(
                path: $openPathPromptText,
                isEditing: $showOpenPathPrompt,
                baseDirectory: currentPath
            ) { newPath in
                guard let url = PathEditorSheet.resolvedURL(for: newPath, relativeTo: currentPath),
                      FileManager.default.fileExists(atPath: url.path) else {
                    return
                }
                currentPath = url
            }
        }
        .alert("Move to Trash?", isPresented: $showTrashConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingTrashURLs = []
            }
            Button("Move to Trash", role: .destructive) {
                performDelete(urls: pendingTrashURLs)
            }
        } message: {
            Text(pendingTrashURLs.count == 1
                ? "Selected item will be moved to Trash."
                : "\(pendingTrashURLs.count) selected items will be moved to Trash.")
        }
        .onChange(of: externalCommand) { _, newCommand in
            guard let newCommand else { return }
            handleExternalCommand(newCommand)
        }
    }

    // MARK: - Actions

    private func handleOpen(_ file: FileItem) {
        onInteraction?()
        if file.isDirectory {
            currentPath = file.path
        } else {
            NSWorkspace.shared.open(file.path)
        }
    }

    @discardableResult
    private func handleDroppedURLs(_ urls: [URL], to destinationDirectory: URL) -> Bool {
        onInteraction?()

        let destination = destinationDirectory.standardizedFileURL
        var affectedDirectories = Set([destination.path])
        for url in urls where url.isFileURL {
            affectedDirectories.insert(url.standardizedFileURL.deletingLastPathComponent().path)
        }

        guard fileOps.moveFiles(urls: urls, to: destination) else { return false }

        NotificationCenter.default.post(
            name: .fileSystemEntriesMoved,
            object: nil,
            userInfo: [FileMoveNotificationUserInfoKey.affectedDirectories: Array(affectedDirectories)]
        )

        loadFiles()
        return true
    }

    private func handleSelect(_ file: FileItem, extend: Bool) {
        onInteraction?()
        let now = ProcessInfo.processInfo.systemUptime

        if extend {
            if selectedFiles.contains(file.path) {
                selectedFiles.remove(file.path)
            } else {
                selectedFiles.insert(file.path)
            }
            lastClickedURL = nil
            lastClickTimestamp = 0
        } else {
            selectedFiles = [file.path]

            if lastClickedURL == file.path,
               now - lastClickTimestamp <= NSEvent.doubleClickInterval {
                lastClickedURL = nil
                lastClickTimestamp = 0
                handleOpen(file)
                return
            }

            lastClickedURL = file.path
            lastClickTimestamp = now
        }
    }

    private func handleDeleteRequest() {
        let urls = Array(selectedFiles)
        guard !urls.isEmpty else { return }

        if confirmBeforeDelete {
            pendingTrashURLs = urls
            showTrashConfirmation = true
        } else {
            performDelete(urls: urls)
        }
    }

    private func performDelete(urls: [URL]) {
        guard !urls.isEmpty else { return }
        _ = fileOps.moveToTrash(urls: urls)
        selectedFiles.removeAll()
        pendingTrashURLs = []
        showTrashConfirmation = false
        loadFiles()
        publishPreviewSelection()
    }

    private func publishPreviewSelection() {
        guard let firstSelectedURL = selectedFiles.first,
              let selectedFile = files.first(where: { $0.path == firstSelectedURL }) else {
            previewRequestID = UUID()
            onPreviewSelectionChange?(nil)
            return
        }

        let requestID = UUID()
        previewRequestID = requestID
        onPreviewSelectionChange?(FilePreviewItem(file: selectedFile, info: nil))

        DispatchQueue.global(qos: .userInitiated).async {
            let info = fileOps.getFileInfo(url: selectedFile.path)
            let item = FilePreviewItem(file: selectedFile, info: info)

            DispatchQueue.main.async {
                guard self.previewRequestID == requestID,
                      self.selectedFiles == Set([selectedFile.path]) else { return }
                self.onPreviewSelectionChange?(item)
            }
        }
    }

    private func beginRename(_ file: FileItem) {
        renamingFile = file.path
        renameText = file.name
    }

    private func commitRename() {
        guard let url = renamingFile else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent else {
            renamingFile = nil
            return
        }
        _ = fileOps.renameFile(at: url, to: newName)
        renamingFile = nil
        loadFiles()
    }

    private func showInfo(for file: FileItem) {
        getInfoTarget = fileOps.getFileInfo(url: file.path)
        showGetInfo = true
    }

    private func handleExternalCommand(_ command: ExternalCommand) {
        switch command {
        case .duplicate:
            let urls = Array(selectedFiles)
            guard !urls.isEmpty else { return }
            fileOps.duplicateFiles(urls: urls, in: currentPath)
            loadFiles()

        case .copy:
            let urls = Array(selectedFiles)
            guard !urls.isEmpty else { return }
            fileOps.copyFiles(urls: urls)

        case .cut:
            let urls = Array(selectedFiles)
            guard !urls.isEmpty else { return }
            fileOps.cutFiles(urls: urls)

        case .paste:
            fileOps.pasteFiles(to: currentPath)
            loadFiles()

        case .selectAll:
            selectedFiles = Set(filteredFiles.map(\.path))

        case .quickLook:
            let urls = Array(selectedFiles)
            guard !urls.isEmpty else { return }
            QuickLookCoordinator.shared.preview(urls: urls)

        case .getInfo:
            guard let url = selectedFiles.first,
                  let file = files.first(where: { $0.path == url }) else { return }
            showInfo(for: file)

        case .rename:
            guard let url = selectedFiles.first,
                  let file = files.first(where: { $0.path == url }) else { return }
            beginRename(file)

        case .refresh:
            loadFiles()

        case .openInTerminal:
            openCurrentPathInTerminal()

        case .openPathPrompt:
            openPathPromptText = ""
            showOpenPathPrompt = true
        }

        commandNonce = UUID()
    }

    private func openCurrentPathInTerminal() {
        let escapedPath = currentPath.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(escapedPath)'"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @ViewBuilder
    private func contextMenuForFile(_ file: FileItem) -> some View {
        // Use all selected files if the right-clicked file is part of the selection
        let targetURLs: [URL] = selectedFiles.contains(file.path) && selectedFiles.count > 1
            ? Array(selectedFiles)
            : [file.path]

        creationContextMenuItems()
        Divider()
        Button("Open") { handleOpen(file) }
        Button("Open With...") {
            NSWorkspace.shared.open(
                targetURLs,
                withApplicationAt: URL(fileURLWithPath: ""),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targetURLs)
        }
        Divider()
        Button("Rename") { beginRename(file) }
        Button("Duplicate") {
            fileOps.duplicateFiles(urls: targetURLs, in: currentPath)
            loadFiles()
        }
        Button("Copy") { fileOps.copyFiles(urls: targetURLs) }
        Button("Cut") { fileOps.cutFiles(urls: targetURLs) }
        if fileOps.clipboardURLs.count > 0 {
            Button("Paste") {
                fileOps.pasteFiles(to: currentPath)
                loadFiles()
            }
        }
        Divider()
        Button("Quick Look") {
            QuickLookCoordinator.shared.preview(urls: targetURLs)
        }
        Button("Get Info") { showInfo(for: file) }
        Divider()
        Menu("Tags") {
            ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"], id: \.self) { tag in
                Button {
                    for url in targetURLs { toggleTag(tag, on: url) }
                } label: {
                    HStack {
                        Circle()
                            .fill(tagColor(for: tag))
                            .frame(width: 8, height: 8)
                        Text(tag)
                        if file.tags.contains(tag) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !file.tags.isEmpty {
                Divider()
                Button("Remove All Tags") {
                    for url in targetURLs { setTags([], on: url) }
                }
            }
        }

        // Media conversion options (if ffmpeg available and file is media)
        if isMediaFile(file.path) {
            Divider()
            Menu("Convert with ffmpeg") {
                Button("To MP4") { convertMedia(file.path, to: "mp4") }
                Button("To WebM") { convertMedia(file.path, to: "webm") }
                Button("To MP3 (Audio)") { convertMedia(file.path, to: "mp3", audioOnly: true) }
                Button("To GIF") { convertMedia(file.path, to: "gif") }
                Button("To WAV") { convertMedia(file.path, to: "wav", audioOnly: true) }
            }
        }

        Divider()
        Button("Move to Trash", role: .destructive) {
            _ = fileOps.moveToTrash(urls: targetURLs)
            for url in targetURLs { selectedFiles.remove(url) }
            loadFiles()
        }
    }

    @ViewBuilder
    private func creationContextMenuItems() -> some View {
        Button("Add File") {
            NotificationCenter.default.post(name: .createNewFile, object: nil)
        }
        Button("Add Folder") {
            NotificationCenter.default.post(name: .createNewFolder, object: nil)
        }
    }

    private func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let mediaExts = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "flac", "ogg", "aac"]
        return mediaExts.contains(ext)
    }

    private func convertMedia(_ input: URL, to format: String, audioOnly: Bool = false) {
        let output = input.deletingPathExtension().appendingPathExtension(format)
        var options = FFmpegOptions.default

        if audioOnly {
            options.audioCodec = format == "mp3" ? "libmp3lame" : "pcm_s16le"
        }

        Task {
            do {
                try await CLIToolManager.shared.convertMedia(
                    input: input,
                    output: output,
                    options: options
                ) { progress in
                    // Progress tracking could update UI
                }
                await MainActor.run {
                    loadFiles()
                }
            } catch {
                print("Conversion failed: \(error)")
            }
        }
    }

    private func toggleTag(_ tag: String, on url: URL) {
        var currentTags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        if currentTags.contains(tag) {
            currentTags.removeAll { $0 == tag }
        } else {
            currentTags.append(tag)
        }
        setTags(currentTags, on: url)
    }

    private func setTags(_ tags: [String], on url: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.tagNames = tags
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
        loadFiles()
    }

    // MARK: - Computed

    var filteredFiles: [FileItem] {
        var result = files.filter { !$0.isHidden || showHiddenFiles }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    private var selectedSize: Int64 {
        files.filter { selectedFiles.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    // MARK: - File Content View

    private var fileContentView: some View {
        Group {
            switch viewMode {
            case .icon:
                FileIconGridView(
                    files: filteredFiles,
                    selectedFiles: $selectedFiles,
                    iconSize: iconSize,
                    onSelect: handleSelect,
                    onOpen: handleOpen,
                    currentPath: currentPath,
                    gitStatuses: gitStatuses,
                    contextMenuForFile: { file in
                        contextMenuForFile(file)
                    }
                )
            case .list:
                FileListView(
                    files: filteredFiles,
                    selectedFiles: $selectedFiles,
                    onSelect: handleSelect,
                    onOpen: handleOpen,
                    currentPath: currentPath,
                    gitStatuses: gitStatuses,
                    sortColumn: $sortColumn,
                    sortAscending: $sortAscending,
                    contextMenuForFile: { file in
                        contextMenuForFile(file)
                    }
                )
            case .column:
                FileColumnBrowserView(
                    files: filteredFiles,
                    selectedFiles: $selectedFiles,
                    currentPath: $currentPath,
                    onSelect: handleSelect,
                    onOpen: handleOpen,
                    currentDirectoryFiles: filteredFiles,
                    gitStatuses: gitStatuses,
                    contextMenuForFile: { file in
                        contextMenuForFile(file)
                    }
                )
            case .tree:
                FileTreeView(
                    files: filteredFiles,
                    selectedFiles: $selectedFiles,
                    onSelect: handleSelect,
                    onOpen: handleOpen,
                    currentPath: currentPath,
                    gitStatuses: gitStatuses,
                    contextMenuForFile: { file in
                        contextMenuForFile(file)
                    }
                )
            }
        }
    }

    // MARK: - Loading

    private func loadFiles() {
        let targetPath = currentPath
        let includeHidden = showHiddenFiles
        let currentSortColumn = sortColumn
        let currentSortAscending = sortAscending
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loadedFiles: [FileItem]
                let statuses: [String: GitFileStatus]

                if VirtualLocation.isRecents(targetPath) {
                    loadedFiles = SidebarDataProvider.recentFiles(limit: 200)
                    statuses = [:]
                } else if let tagName = VirtualLocation.tagName(for: targetPath) {
                    loadedFiles = SidebarDataProvider.taggedFiles(named: tagName, limit: 400)
                    statuses = [:]
                } else if ApplicationDirectories.isApplicationsRoot(targetPath) {
                    let applicationEntries = ApplicationDirectories.mergedImmediateContents(includeHidden: includeHidden)

                    if query.isEmpty {
                        loadedFiles = applicationEntries.compactMap { FileItem.fromURL($0) }
                    } else {
                        loadedFiles = applicationEntries
                            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
                            .compactMap { FileItem.fromURL($0) }
                    }
                    statuses = [:]
                } else {
                    let fileManager = FileManager.default
                    let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]

                    if !query.isEmpty {
                        let enumerator = fileManager.enumerator(
                            at: targetPath,
                            includingPropertiesForKeys: [
                                .isDirectoryKey,
                                .fileSizeKey,
                                .contentModificationDateKey,
                                .creationDateKey,
                                .tagNamesKey,
                            ],
                            options: options
                        )

                        var recursiveMatches: [FileItem] = []
                        while let url = enumerator?.nextObject() as? URL {
                            if url.lastPathComponent.localizedCaseInsensitiveContains(query),
                               let item = FileItem.fromURL(url) {
                                recursiveMatches.append(item)
                            }
                        }

                        loadedFiles = recursiveMatches
                        statuses = [:]
                    } else {
                        let contents = try fileManager.contentsOfDirectory(
                            at: targetPath,
                            includingPropertiesForKeys: [
                                .isDirectoryKey,
                                .fileSizeKey,
                                .contentModificationDateKey,
                                .creationDateKey,
                                .tagNamesKey,
                            ],
                            options: options
                        )

                        loadedFiles = contents.compactMap { FileItem.fromURL($0) }
                        statuses = GitStatusProvider.status(for: targetPath)
                    }
                }

                let sortedFiles = Self.sortFiles(
                    loadedFiles,
                    column: currentSortColumn,
                    ascending: currentSortAscending
                )

                DispatchQueue.main.async {
                    guard self.currentPath == targetPath else { return }
                    self.files = sortedFiles
                    self.gitStatuses = statuses
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.currentPath == targetPath else { return }
                    self.files = []
                    self.gitStatuses = [:]
                    self.loadError = error.localizedDescription
                }
            }
        }
    }

    private func sortFiles(_ items: [FileItem]) -> [FileItem] {
        Self.sortFiles(items, column: sortColumn, ascending: sortAscending)
    }

    private static func sortFiles(
        _ items: [FileItem],
        column: SortColumn,
        ascending: Bool
    ) -> [FileItem] {
        let sorted = items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch column {
            case .name: return a.name.localizedCompare(b.name) == .orderedAscending
            case .size: return a.size < b.size
            case .modified: return a.modified < b.modified
            case .kind: return a.kindString.localizedCompare(b.kindString) == .orderedAscending
            }
        }
        return ascending ? sorted : sorted.reversed()
    }
}

// MARK: - Preview

#Preview {
    FileBrowserView(
        currentPath: .constant(URL(fileURLWithPath: NSHomeDirectory())),
        viewMode: .constant(.list),
        showHiddenFiles: .constant(false)
    )
    .environmentObject(FileOperations())
}
