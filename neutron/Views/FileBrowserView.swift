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

// MARK: - GitStatus

enum GitFileStatus {
    case modified, staged, untracked, conflict

    var color: Color {
        switch self {
        case .modified: return .orange
        case .staged: return .green
        case .untracked: return .gray
        case .conflict: return .red
        }
    }
}

class GitStatusProvider {
    static func gitRoot(for directory: URL) -> URL? {
        var current = directory
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    static func status(for directory: URL) -> [String: GitFileStatus] {
        guard let root = gitRoot(for: directory) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "-uall"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: GitFileStatus] = [:]
        for line in output.split(separator: "\n") {
            guard line.count >= 4 else { continue }
            let index = line.index(line.startIndex, offsetBy: 0)
            let work = line.index(line.startIndex, offsetBy: 1)
            let filePath = String(line.dropFirst(3))
            let fullPath = root.appendingPathComponent(filePath).path

            let x = line[index]
            let y = line[work]
            if x == "U" || y == "U" {
                result[fullPath] = .conflict
            } else if x != " " && x != "?" {
                result[fullPath] = .staged
            } else if y == "M" || y == "D" {
                result[fullPath] = .modified
            } else if x == "?" && y == "?" {
                result[fullPath] = .untracked
            }
        }
        return result
    }
}

final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct FileItem: Identifiable, Hashable {
    var id: URL { path }
    let name: String
    let isDirectory: Bool
    let size: Int64
    let created: Date
    let modified: Date
    let path: URL
    let tags: [String]

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var isHidden: Bool { name.hasPrefix(".") }

    var nsImage: NSImage {
        FileIconCache.shared.icon(for: path)
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return Self.sizeFormatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        Self.dateFormatter.string(from: modified)
    }

    var kindString: String {
        if isDirectory { return "Folder" }
        if let utType = UTType(filenameExtension: path.pathExtension) {
            return utType.localizedDescription ?? path.pathExtension.uppercased()
        }
        return path.pathExtension.isEmpty ? "Document" : path.pathExtension.uppercased()
    }

    nonisolated static func fromURL(_ url: URL, values: URLResourceValues? = nil) -> FileItem? {
        do {
            let resolvedValues = try values ?? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .tagNamesKey,
            ])
            let isDirectory = resolvedValues.isDirectory ?? false
            let size = Int64(resolvedValues.fileSize ?? 0)
            let created = resolvedValues.creationDate ?? resolvedValues.contentModificationDate ?? Date()
            let modified = resolvedValues.contentModificationDate ?? created
            let tags = resolvedValues.tagNames ?? []

            return FileItem(
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                size: size,
                created: created,
                modified: modified,
                path: url,
                tags: tags
            )
        } catch {
            return nil
        }
    }
}

struct FilePreviewItem: Identifiable, Equatable {
    let id: URL
    let name: String
    let isDirectory: Bool
    let path: URL
    let kind: String
    let size: String
    let location: String
    let created: String?
    let modified: String?
    let permissions: String?
    let itemCount: Int?

    init(file: FileItem, info: FileInfo?) {
        self.id = file.path
        self.name = file.name
        self.isDirectory = file.isDirectory
        self.path = file.path
        self.kind = info?.kind ?? file.kindString
        self.size = {
            if let info {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                return formatter.string(fromByteCount: info.size)
            }
            return file.formattedSize
        }()
        self.location = info?.path ?? file.path.path
        self.created = info?.created.formatted()
        self.modified = info?.modified.formatted() ?? file.formattedDate
        self.permissions = info?.permissions
        self.itemCount = info?.itemCount
    }
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
    }

    @Binding var currentPath: URL
    @Binding var viewMode: ViewMode
    @Binding var showHiddenFiles: Bool
    var searchText: String = ""
    var showsPathBar: Bool = true
    var showsStatusBar: Bool = true
    var externalCommand: ExternalCommand? = nil
    var onPreviewSelectionChange: ((FilePreviewItem?) -> Void)? = nil

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

    enum SortColumn {
        case name, size, modified, kind
    }

    enum ViewMode: String, CaseIterable {
        case icon = "Icon"
        case list = "List"
        case column = "Column"

        var icon: String {
            switch self {
            case .icon: return "square.grid.2x2"
            case .list: return "list.bullet"
            case .column: return "rectangle.split.3x1"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    switch viewMode {
                    case .icon:
                        IconGridView(
                            files: filteredFiles,
                            selectedFiles: $selectedFiles,
                            gitStatuses: gitStatuses,
                            iconSize: iconSize,
                            onOpen: handleOpen,
                            onSelect: handleSelect,
                            contextMenu: contextMenuForFile,
                            onDropToFolder: handleDroppedURLs(_:to:),
                            onDropToCurrentDirectory: { urls in
                                handleDroppedURLs(urls, to: currentPath)
                            }
                        )
                    case .list:
                        FileListView(
                            files: filteredFiles,
                            selectedFiles: $selectedFiles,
                            sortColumn: $sortColumn,
                            sortAscending: $sortAscending,
                            renamingFile: $renamingFile,
                            renameText: $renameText,
                            gitStatuses: gitStatuses,
                            showSizeColumn: showSizeColumn,
                            showDateColumn: showDateColumn,
                            showKindColumn: showKindColumn,
                            onOpen: handleOpen,
                            onSelect: handleSelect,
                            onRenameCommit: commitRename,
                            contextMenu: contextMenuForFile,
                            onDropToFolder: handleDroppedURLs(_:to:),
                            onDropToCurrentDirectory: { urls in
                                handleDroppedURLs(urls, to: currentPath)
                            }
                        )
                    case .column:
                        ColumnView(
                            currentPath: $currentPath,
                            showHiddenFiles: showHiddenFiles,
                            searchText: searchText,
                            onPreviewSelectionChange: { selectedFile in
                                onPreviewSelectionChange?(makePreviewItem(for: selectedFile))
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
                .frame(height: 26)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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
        .sheet(isPresented: $showGetInfo) {
            if let info = getInfoTarget {
                GetInfoView(info: info, isPresented: $showGetInfo)
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
        if file.isDirectory {
            currentPath = file.path
        } else {
            NSWorkspace.shared.open(file.path)
        }
    }

    @discardableResult
    private func handleDroppedURLs(_ urls: [URL], to destinationDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let destination = destinationDirectory.standardizedFileURL
        var moved = false

        for sourceURL in urls where sourceURL.isFileURL {
            let source = sourceURL.standardizedFileURL
            let parent = source.deletingLastPathComponent().standardizedFileURL

            if source == destination || parent == destination {
                continue
            }

            if source.hasDirectoryPath,
               destination.path.hasPrefix(source.path + "/") {
                continue
            }

            var candidate = destination.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) {
                candidate = uniqueDestinationURL(for: source, in: destination)
            }

            do {
                try fileManager.moveItem(at: source, to: candidate)
                moved = true
            } catch {
                fileOps.lastError = "Failed to move \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if moved {
            loadFiles()
        }

        return moved
    }

    private func uniqueDestinationURL(for source: URL, in directory: URL) -> URL {
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(base) \(counter)"
            } else {
                candidateName = "\(base) \(counter).\(ext)"
            }

            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }

            counter += 1
        }
    }

    private func handleSelect(_ file: FileItem, extend: Bool) {
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

    private func makePreviewItem(for file: FileItem?) -> FilePreviewItem? {
        guard let file else { return nil }
        return FilePreviewItem(file: file, info: nil)
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
        Button("Open") { handleOpen(file) }
        Button("Open With...") {
            NSWorkspace.shared.open(
                [file.path],
                withApplicationAt: URL(fileURLWithPath: ""),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([file.path])
        }
        Divider()
        Button("Rename") { beginRename(file) }
        Button("Duplicate") {
            fileOps.duplicateFiles(urls: [file.path], in: currentPath)
            loadFiles()
        }
        Button("Copy") { fileOps.copyFiles(urls: [file.path]) }
        Button("Cut") { fileOps.cutFiles(urls: [file.path]) }
        if fileOps.clipboardURLs.count > 0 {
            Button("Paste") {
                fileOps.pasteFiles(to: currentPath)
                loadFiles()
            }
        }
        Divider()
        Button("Quick Look") {
            QuickLookCoordinator.shared.preview(urls: [file.path])
        }
        Button("Get Info") { showInfo(for: file) }
        Divider()
        Menu("Tags") {
            ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"], id: \.self) { tag in
                Button {
                    toggleTag(tag, on: file.path)
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
                    setTags([], on: file.path)
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
            _ = fileOps.moveToTrash(urls: [file.path])
            selectedFiles.remove(file.path)
            loadFiles()
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

    // MARK: - Loading

    private func loadFiles() {
        let targetPath = currentPath
        let includeHidden = showHiddenFiles
        let currentSortColumn = sortColumn
        let currentSortAscending = sortAscending

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
                } else {
                    let fileManager = FileManager.default
                    let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
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

// MARK: - StatusBarView

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

// MARK: - GetInfoView

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

// MARK: - PathBarView

struct PathBarView: View {
    @Binding var currentPath: URL
    @State private var isEditing = false
    @State private var editedPath: String = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button(action: goToHome) {
                    Image(systemName: "house")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Go to home")

                if !pathComponents.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    PathComponentButton(
                        name: component.name,
                        url: component.url,
                        onNavigate: { url in currentPath = url }
                    )

                    if index < pathComponents.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentPath.path, forType: .string)
            }
            Button("Open in Terminal") {
                openTerminal()
            }
            Button("Open in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: currentPath.path)
            }
            Divider()
            Button("Go to Folder...") {
                isEditing = true
                editedPath = currentPath.path
            }
        }
        .sheet(isPresented: $isEditing) {
            PathEditorSheet(path: $editedPath, isEditing: $isEditing) { newPath in
                let url = URL(fileURLWithPath: newPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    currentPath = url
                }
            }
        }
    }

    struct PathPart: Identifiable {
        let name: String
        let url: URL
        var id: String { "\(name)|\(url.absoluteString)" }
    }

    var pathComponents: [PathPart] {
        if VirtualLocation.isRecents(currentPath) {
            return [PathPart(name: "Recents", url: currentPath)]
        }

        if let tagName = VirtualLocation.tagName(for: currentPath) {
            return [PathPart(name: "Tags", url: currentPath), PathPart(name: tagName, url: currentPath)]
        }

        let components = currentPath.pathComponents.filter { $0 != "/" }
        var url = URL(fileURLWithPath: "/")
        return components.map { component in
            url = url.appendingPathComponent(component)
            return PathPart(name: component, url: url)
        }
    }

    func goToHome() {
        currentPath = FileManager.default.homeDirectoryForCurrentUser
    }

    func openTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(currentPath.path)'"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

struct PathComponentButton: View {
    let name: String
    let url: URL
    var onNavigate: (URL) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            Button(name) {
                onNavigate(url)
            }
            Divider()
            ForEach(siblingDirectories, id: \.self) { sibling in
                Button(sibling.lastPathComponent) {
                    onNavigate(sibling)
                }
            }
        } label: {
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isHovering ? Color.accentColor.opacity(0.2) : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var siblingDirectories: [URL] {
        guard url.isFileURL else { return [] }
        let parent = url.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { sibling in
                let isDir = (try? sibling.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDir && sibling != url
            }
            .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
    }
}

struct PathEditorSheet: View {
    @Binding var path: String
    @Binding var isEditing: Bool
    var onCommit: (String) -> Void

    var body: some View {
        VStack {
            Text("Go to Folder")
                .font(.headline)
            TextField("Path", text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
            HStack {
                Button("Cancel") {
                    isEditing = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Go") {
                    onCommit(path)
                    isEditing = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

// MARK: - FileListView

struct FileListView: View {
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    @Binding var sortColumn: FileBrowserView.SortColumn
    @Binding var sortAscending: Bool
    @Binding var renamingFile: URL?
    @Binding var renameText: String
    var gitStatuses: [String: GitFileStatus]
    var showSizeColumn: Bool
    var showDateColumn: Bool
    var showKindColumn: Bool
    var onOpen: (FileItem) -> Void
    var onSelect: (FileItem, Bool) -> Void
    var onRenameCommit: () -> Void
    var contextMenu: (FileItem) -> AnyView
    var onDropToFolder: ([URL], URL) -> Bool
    var onDropToCurrentDirectory: ([URL]) -> Bool

    @AppStorage("listNameColumnWidth") private var nameColumnWidth: Double = 200
    @AppStorage("listSizeColumnWidth") private var sizeColumnWidth: Double = 84
    @AppStorage("listDateColumnWidth") private var dateColumnWidth: Double = 144
    @AppStorage("listKindColumnWidth") private var kindColumnWidth: Double = 118

    init(
        files: [FileItem],
        selectedFiles: Binding<Set<URL>>,
        sortColumn: Binding<FileBrowserView.SortColumn>,
        sortAscending: Binding<Bool>,
        renamingFile: Binding<URL?>,
        renameText: Binding<String>,
        gitStatuses: [String: GitFileStatus] = [:],
        showSizeColumn: Bool = true,
        showDateColumn: Bool = true,
        showKindColumn: Bool = true,
        onOpen: @escaping (FileItem) -> Void,
        onSelect: @escaping (FileItem, Bool) -> Void,
        onRenameCommit: @escaping () -> Void,
        contextMenu: @escaping (FileItem) -> some View,
        onDropToFolder: @escaping ([URL], URL) -> Bool,
        onDropToCurrentDirectory: @escaping ([URL]) -> Bool
    ) {
        self.files = files
        self._selectedFiles = selectedFiles
        self._sortColumn = sortColumn
        self._sortAscending = sortAscending
        self._renamingFile = renamingFile
        self._renameText = renameText
        self.gitStatuses = gitStatuses
        self.showSizeColumn = showSizeColumn
        self.showDateColumn = showDateColumn
        self.showKindColumn = showKindColumn
        self.onOpen = onOpen
        self.onSelect = onSelect
        self.onRenameCommit = onRenameCommit
        self.contextMenu = { file in AnyView(contextMenu(file)) }
        self.onDropToFolder = onDropToFolder
        self.onDropToCurrentDirectory = onDropToCurrentDirectory
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = resolvedColumns(for: geometry.size.width)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ResizableSortableHeader(
                        title: "Name",
                        column: .name,
                        currentColumn: $sortColumn,
                        ascending: $sortAscending,
                        width: $nameColumnWidth,
                        minWidth: Double(columns.nameMinWidth),
                        alignment: .leading,
                        isFlexible: true
                    )

                    if columns.showSize {
                        ResizableSortableHeader(
                            title: "Size",
                            column: .size,
                            currentColumn: $sortColumn,
                            ascending: $sortAscending,
                            width: $sizeColumnWidth,
                            minWidth: 68,
                            alignment: .trailing
                        )
                    }

                    if columns.showDate {
                        ResizableSortableHeader(
                            title: "Date Modified",
                            column: .modified,
                            currentColumn: $sortColumn,
                            ascending: $sortAscending,
                            width: $dateColumnWidth,
                            minWidth: 110,
                            alignment: .trailing
                        )
                    }

                    if columns.showKind {
                        ResizableSortableHeader(
                            title: "Kind",
                            column: .kind,
                            currentColumn: $sortColumn,
                            ascending: $sortAscending,
                            width: $kindColumnWidth,
                            minWidth: 90,
                            alignment: .trailing
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List(selection: $selectedFiles) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        FileListRow(
                            file: file,
                            isSelected: selectedFiles.contains(file.path),
                            isRenaming: renamingFile == file.path,
                            renameText: $renameText,
                            onRenameCommit: onRenameCommit,
                            gitStatus: gitStatuses[file.path.path],
                            showSizeColumn: columns.showSize,
                            showDateColumn: columns.showDate,
                            showKindColumn: columns.showKind,
                            nameColumnWidth: columns.nameMinWidth,
                            sizeColumnWidth: CGFloat(sizeColumnWidth),
                            dateColumnWidth: CGFloat(dateColumnWidth),
                            kindColumnWidth: CGFloat(kindColumnWidth),
                            onDropURLs: onDropToFolder
                        )
                        .listRowBackground(rowBackground(for: file, index: index))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .tag(file.path)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(file, NSEvent.modifierFlags.contains(.command))
                        }
                        .contextMenu { contextMenu(file) }
                        .draggable(file.path) {
                            FileDragPreview(name: file.name, icon: file.nsImage)
                        }
                    }
                }
                .listStyle(.plain)
                .tint(.accentColor)
                .environment(\.defaultMinListRowHeight, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    onDropToCurrentDirectory(urls)
                }
            }
        }
        .onAppear {
            normalizeColumnWidths()
        }
    }

    private struct EffectiveListColumns {
        let showSize: Bool
        let showDate: Bool
        let showKind: Bool
        let nameMinWidth: CGFloat
    }

    private func resolvedColumns(for availableWidth: CGFloat) -> EffectiveListColumns {
        let baseNameWidth: CGFloat = 120
        let total = max(availableWidth - 16, baseNameWidth)
        var remaining = total - baseNameWidth

        var showSize = false
        var showDate = false
        var showKind = false

        if showSizeColumn, remaining >= CGFloat(sizeColumnWidth) {
            showSize = true
            remaining -= CGFloat(sizeColumnWidth)
        }

        if showDateColumn, remaining >= CGFloat(dateColumnWidth) {
            showDate = true
            remaining -= CGFloat(dateColumnWidth)
        }

        if showKindColumn, remaining >= CGFloat(kindColumnWidth) {
            showKind = true
        }

        return EffectiveListColumns(
            showSize: showSize,
            showDate: showDate,
            showKind: showKind,
            nameMinWidth: baseNameWidth
        )
    }

    private func normalizeColumnWidths() {
        if nameColumnWidth == 300, sizeColumnWidth == 96, dateColumnWidth == 170, kindColumnWidth == 140 {
            nameColumnWidth = 200
            sizeColumnWidth = 84
            dateColumnWidth = 144
            kindColumnWidth = 118
        }

        nameColumnWidth = min(max(nameColumnWidth, 140), 520)
        sizeColumnWidth = min(max(sizeColumnWidth, 68), 240)
        dateColumnWidth = min(max(dateColumnWidth, 110), 320)
        kindColumnWidth = min(max(kindColumnWidth, 90), 260)
    }

    private func alternatingRowColor(for index: Int) -> Color {
        let colors = NSColor.alternatingContentBackgroundColors
        guard colors.count > 1 else { return Color.clear }
        return Color(nsColor: colors[index.isMultiple(of: 2) ? 0 : 1])
    }

    private func rowBackground(for file: FileItem, index: Int) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selectedFiles.contains(file.path) ? Color.neutronSelectionAccent.opacity(0.18) : alternatingRowColor(for: index))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selectedFiles.contains(file.path) ? Color.neutronSelectionAccent.opacity(0.75) : Color.clear, lineWidth: 1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }
}

private struct ResizableSortableHeader: View {
    let title: String
    let column: FileBrowserView.SortColumn
    @Binding var currentColumn: FileBrowserView.SortColumn
    @Binding var ascending: Bool
    @Binding var width: Double
    let minWidth: Double
    let alignment: Alignment
    var isFlexible: Bool = false

    var body: some View {
        Button {
            if currentColumn == column {
                ascending.toggle()
            } else {
                currentColumn = column
                ascending = true
            }
        } label: {
            HStack(spacing: 2) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.system(size: 11, weight: currentColumn == column ? .semibold : .regular))
                    .lineLimit(1)
                if currentColumn == column {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundColor(currentColumn == column ? .primary : .secondary)
            .frame(
                minWidth: isFlexible ? minWidth : nil,
                idealWidth: isFlexible ? width : nil,
                maxWidth: isFlexible ? .infinity : width,
                alignment: alignment
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            ColumnResizeHandle(width: $width, minWidth: minWidth)
        }
    }
}

private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double = 640

    @State private var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = width
                        }
                        let start = dragStartWidth ?? width
                        width = min(max(start + value.translation.width, minWidth), maxWidth)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct FileListRow: View {
    let file: FileItem
    var isSelected: Bool = false
    var isRenaming: Bool = false
    @Binding var renameText: String
    var onRenameCommit: () -> Void
    var gitStatus: GitFileStatus? = nil
    var showSizeColumn: Bool = true
    var showDateColumn: Bool = true
    var showKindColumn: Bool = true
    var nameColumnWidth: CGFloat
    var sizeColumnWidth: CGFloat
    var dateColumnWidth: CGFloat
    var kindColumnWidth: CGFloat
    var onDropURLs: ([URL], URL) -> Bool = { _, _ in false }

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(nsImage: file.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)

                if isRenaming {
                    TextField("", text: $renameText, onCommit: onRenameCommit)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(file.name)
                        .foregroundStyle(isSelected ? .primary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let status = gitStatus {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }

                if !file.tags.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(file.tags.prefix(3), id: \.self) { tag in
                            Circle()
                                .fill(tagColor(for: tag))
                                .frame(width: 7, height: 7)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(minWidth: nameColumnWidth, maxWidth: .infinity, alignment: .leading)

            if showSizeColumn {
                Text(file.formattedSize)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: sizeColumnWidth, alignment: .trailing)
            }
            if showDateColumn {
                Text(file.formattedDate)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: dateColumnWidth, alignment: .trailing)
            }
            if showKindColumn {
                Text(file.kindString)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: kindColumnWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .overlay {
            if file.isDirectory && isDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.neutronSelectionAccent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard file.isDirectory else { return false }
            return onDropURLs(urls, file.path)
        } isTargeted: { targeting in
            isDropTargeted = targeting && file.isDirectory
        }
    }
}

func tagColor(for tagName: String) -> Color {
    switch tagName.lowercased() {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "gray", "grey": return .gray
    default: return .secondary
    }
}

// MARK: - IconGridView

struct IconGridView: View {
    let files: [FileItem]
    @Binding var selectedFiles: Set<URL>
    var gitStatuses: [String: GitFileStatus]
    var iconSize: Double = 48
    var onOpen: (FileItem) -> Void
    var onSelect: (FileItem, Bool) -> Void
    var contextMenu: (FileItem) -> AnyView
    var onDropToFolder: ([URL], URL) -> Bool
    var onDropToCurrentDirectory: ([URL]) -> Bool

    init(
        files: [FileItem],
        selectedFiles: Binding<Set<URL>>,
        gitStatuses: [String: GitFileStatus] = [:],
        iconSize: Double = 48,
        onOpen: @escaping (FileItem) -> Void,
        onSelect: @escaping (FileItem, Bool) -> Void,
        contextMenu: @escaping (FileItem) -> some View,
        onDropToFolder: @escaping ([URL], URL) -> Bool,
        onDropToCurrentDirectory: @escaping ([URL]) -> Bool
    ) {
        self.files = files
        self._selectedFiles = selectedFiles
        self.gitStatuses = gitStatuses
        self.iconSize = iconSize
        self.onOpen = onOpen
        self.onSelect = onSelect
        self.contextMenu = { file in AnyView(contextMenu(file)) }
        self.onDropToFolder = onDropToFolder
        self.onDropToCurrentDirectory = onDropToCurrentDirectory
    }

    var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: max(iconSize + 24, 72), maximum: max(iconSize + 56, 108)), spacing: 10)
        ]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(files) { file in
                    IconGridItem(
                        file: file,
                        isSelected: selectedFiles.contains(file.path),
                        gitStatus: gitStatuses[file.path.path],
                        iconSize: iconSize,
                        onDropURLs: onDropToFolder
                    )
                        .onTapGesture {
                            onSelect(file, NSEvent.modifierFlags.contains(.command))
                        }
                        .contextMenu { contextMenu(file) }
                        .draggable(file.path) {
                            FileDragPreview(name: file.name, icon: file.nsImage)
                        }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            onDropToCurrentDirectory(urls)
        }
    }
}

struct IconGridItem: View {
    let file: FileItem
    let isSelected: Bool
    var gitStatus: GitFileStatus? = nil
    var iconSize: Double = 48
    var onDropURLs: ([URL], URL) -> Bool = { _, _ in false }

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: file.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)

                if let status = gitStatus {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: 2)
                }
            }

            HStack(spacing: 2) {
                if !file.tags.isEmpty {
                    ForEach(file.tags.prefix(3), id: \.self) { tag in
                        Circle()
                            .fill(tagColor(for: tag))
                            .frame(width: 6, height: 6)
                    }
                }
            }

            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: max(iconSize + 32, 80))
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.neutronSelectionAccent.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.neutronSelectionAccent : Color.clear, lineWidth: 2)
        )
        .overlay {
            if file.isDirectory && isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.neutronSelectionAccent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard file.isDirectory else { return false }
            return onDropURLs(urls, file.path)
        } isTargeted: { targeting in
            isDropTargeted = targeting && file.isDirectory
        }
    }
}

private struct FileDragPreview: View {
    let name: String
    let icon: NSImage

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
            Text(name)
                .lineLimit(1)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.neutronSelectionAccent.opacity(0.7), lineWidth: 1)
        }
    }
}

// MARK: - ColumnView

struct ColumnView: View {
    @Binding var currentPath: URL
    var showHiddenFiles: Bool
    var searchText: String
    var onPreviewSelectionChange: (FileItem?) -> Void

    @State private var primaryFiles: [FileItem] = []
    @State private var secondaryFiles: [FileItem] = []
    @State private var primarySelection: URL?
    @State private var secondarySelection: URL?
    @State private var lastClickedURL: URL?
    @State private var lastClickTimestamp: TimeInterval = 0

    var body: some View {
        HSplitView {
            ColumnListView(
                title: currentPath.lastPathComponent.isEmpty ? "/" : currentPath.lastPathComponent,
                files: filtered(files: primaryFiles),
                selectedURL: $primarySelection,
                onSelect: handlePrimarySelect,
                onOpen: handlePrimaryOpen
            )
            .frame(minWidth: 180, idealWidth: 240)

            ColumnListView(
                title: secondaryTitle,
                files: filtered(files: secondaryFiles),
                selectedURL: $secondarySelection,
                onSelect: handleSecondarySelect,
                onOpen: handleSecondaryOpen
            )
            .frame(minWidth: 180, idealWidth: 240)
        }
        .onAppear {
            loadPrimaryFiles(for: currentPath)
            onPreviewSelectionChange(nil)
        }
        .onChange(of: currentPath) { _, newPath in
            loadPrimaryFiles(for: newPath)
            onPreviewSelectionChange(nil)
        }
    }

    private var secondaryTitle: String {
        if let selectedDir = primaryFiles.first(where: { $0.path == primarySelection && $0.isDirectory }) {
            return selectedDir.name
        }
        return "Items"
    }

    private func filtered(files: [FileItem]) -> [FileItem] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    private func handlePrimarySelect(_ file: FileItem) {
        let shouldOpen = registerClick(for: file)
        secondarySelection = nil
        if file.isDirectory {
            onPreviewSelectionChange(nil)
            loadSecondaryFiles(for: file.path)
            if shouldOpen {
                currentPath = file.path
            }
        } else {
            secondaryFiles = []
            onPreviewSelectionChange(file)
            if shouldOpen {
                NSWorkspace.shared.open(file.path)
            }
        }
    }

    private func handlePrimaryOpen(_ file: FileItem) {
        if file.isDirectory {
            currentPath = file.path
        } else {
            NSWorkspace.shared.open(file.path)
        }
    }

    private func handleSecondarySelect(_ file: FileItem) {
        onPreviewSelectionChange(file)
        if registerClick(for: file) {
            handleSecondaryOpen(file)
        }
    }

    private func handleSecondaryOpen(_ file: FileItem) {
        if file.isDirectory {
            currentPath = file.path
        } else {
            NSWorkspace.shared.open(file.path)
        }
    }

    private func loadPrimaryFiles(for path: URL) {
        let expectedPath = path
        loadFiles(at: path) { items in
            guard self.currentPath == expectedPath else { return }
            self.primaryFiles = items
            self.primarySelection = nil
            self.secondaryFiles = []
            self.secondarySelection = nil
        }
    }

    private func loadSecondaryFiles(for path: URL) {
        let expectedPath = path
        loadFiles(at: path) { items in
            let selectedIsStillExpected = self.primaryFiles.contains {
                $0.path == self.primarySelection && $0.path == expectedPath
            }
            guard selectedIsStillExpected else { return }
            self.secondaryFiles = items
            self.secondarySelection = nil
        }
    }

    private func loadFiles(at path: URL, apply: @escaping ([FileItem]) -> Void) {
        let includeHidden = showHiddenFiles
        DispatchQueue.global(qos: .userInitiated).async {
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .tagNamesKey],
                options: options
            )) ?? []

            let items = urls.compactMap { FileItem.fromURL($0) }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCompare(b.name) == .orderedAscending
                }

            DispatchQueue.main.async {
                apply(items)
            }
        }
    }

    private func registerClick(for file: FileItem) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastClickedURL = file.path
            lastClickTimestamp = now
        }

        guard lastClickedURL == file.path,
              now - lastClickTimestamp <= NSEvent.doubleClickInterval else {
            return false
        }

        lastClickedURL = nil
        lastClickTimestamp = 0
        return true
    }
}

private struct ColumnListView: View {
    let title: String
    let files: [FileItem]
    @Binding var selectedURL: URL?
    var onSelect: (FileItem) -> Void
    var onOpen: (FileItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(files.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            List(selection: $selectedURL) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Image(nsImage: file.nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 15, height: 15)

                        Text(file.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        Text(file.formattedDate)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if file.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .listRowBackground(rowBackground(for: file))
                    .contentShape(Rectangle())
                    .tag(file.path)
                    .onTapGesture {
                        selectedURL = file.path
                        onSelect(file)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .tint(.accentColor)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func rowBackground(for file: FileItem) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selectedURL == file.path ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selectedURL == file.path ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }
}

struct FinderPreviewColumn: View {
    let file: FilePreviewItem

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Preview")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    FinderThumbnailView(url: file.path, isDirectory: file.isDirectory)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    Text(file.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)

                    VStack(alignment: .leading, spacing: 6) {
                        PreviewInfoRow(label: "Kind", value: file.kind)
                        PreviewInfoRow(label: "Size", value: file.size)
                        PreviewInfoRow(label: "Location", value: file.location)
                        if let created = file.created {
                            PreviewInfoRow(label: "Created", value: created)
                        }
                        if let modified = file.modified {
                            PreviewInfoRow(label: "Modified", value: modified)
                        }
                        if let permissions = file.permissions {
                            PreviewInfoRow(label: "Permissions", value: permissions)
                        }
                        if let itemCount = file.itemCount {
                            PreviewInfoRow(label: "Items", value: "\(itemCount)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct FinderThumbnailView: View {
    let url: URL
    let isDirectory: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 170, height: 170)
        .onAppear(perform: loadThumbnail)
        .onChange(of: url) { _, _ in
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard !isDirectory else {
            thumbnail = nil
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            DispatchQueue.main.async {
                self.thumbnail = representation?.nsImage
            }
        }
    }
}

private struct PreviewInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
        }
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
