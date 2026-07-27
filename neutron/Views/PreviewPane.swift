import SwiftUI
import Quartz
import QuickLookThumbnailing
import PDFKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Preview Pane

struct FinderPreviewColumn: View {
    let file: FilePreviewItem?
    var onRename: ((URL, String) -> Void)?
    var onTagsChanged: ((URL, [String]) -> Void)?
    var onRefresh: (() -> Void)?
    var onPermissionsChanged: ((URL, UInt16) -> Void)?

    @EnvironmentObject private var fileOps: FileOperations
    @State private var isEditingName = false
    @State private var editingName = ""
    @State private var showingTagMenu = false
    @AppStorage("previewShowMetadata") private var showMetadata = true

    var body: some View {
        let effectiveFile = file ?? fileOps.currentPreviewItem

        VStack(spacing: 0) {
            if let file = effectiveFile {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection(file: file)
                        UnifiedPreviewContentView(
                            file: file,
                            showMetadata: showMetadata,
                            showingTagMenu: $showingTagMenu,
                            onTagsChanged: onTagsChanged,
                            onRefresh: onRefresh,
                            onPermissionsChanged: onPermissionsChanged
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState
            }
        }
        .background(.background)
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection(file: FilePreviewItem) -> some View {
        PreviewHeader(file: file, isEditingName: $isEditingName, editingName: $editingName, onRename: onRename)
            .padding(.top, 22)
            .padding(.bottom, 16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            VStack(spacing: 2) {
                Text("No Selection")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Select a file to preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview Header

private struct PreviewHeader: View {
    let file: FilePreviewItem
    @Binding var isEditingName: Bool
    @Binding var editingName: String
    var onRename: ((URL, String) -> Void)?

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 10) {
            thumbnailView
                .frame(width: 96, height: 96)

            if isEditingName {
                TextField("", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .onSubmit { commitRename() }
                    .onExitCommand { isEditingName = false }
            } else {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
                    .onTapGesture(count: 2) {
                        editingName = file.name
                        isEditingName = true
                    }
            }

            Text(file.kind)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .task(id: file.path) {
            guard !file.isDirectory else { thumbnail = nil; return }
            let request = QLThumbnailGenerator.Request(
                fileAt: file.path,
                size: CGSize(width: 288, height: 288),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let nsImage = thumbnail {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
        }
    }

    private func commitRename() {
        guard !editingName.isEmpty, editingName != file.name else {
            isEditingName = false
            return
        }
        onRename?(file.path, editingName)
        isEditingName = false
    }
}

// MARK: - Content Preview

private struct ContentPreviewContainer: View {
    let file: FilePreviewItem

    var body: some View {
        let ext = file.path.pathExtension.lowercased()

        Group {
            if isTextFile(ext: ext) || isCodeFile(ext: ext) {
                TextPreviewView(url: file.path)
                    .frame(height: 200)
            } else if ext == "pdf" {
                PDFPreviewView(url: file.path)
                    .frame(height: 240)
            } else if isImageFile(ext: ext) {
                ImagePreviewView(url: file.path)
                    .frame(height: 200)
            } else if isVideoFile(ext: ext) {
                VideoPreviewView(url: file.path)
                    .frame(height: 200)
            } else if isAudioFile(ext: ext) {
                AudioPreviewView(url: file.path)
                    .frame(height: 80)
            } else {
                QuickLookPreviewView(url: file.path)
                    .frame(height: 200)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - Unified Content + Metadata Preview

/// Combines the file content preview with inline metadata into one unified view.
private struct UnifiedPreviewContentView: View {
    let file: FilePreviewItem
    let showMetadata: Bool
    @Binding var showingTagMenu: Bool
    var onTagsChanged: ((URL, [String]) -> Void)?
    var onRefresh: (() -> Void)?
    var onPermissionsChanged: ((URL, UInt16) -> Void)?

    @AppStorage("previewMetadataExpanded") private var metadataExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            // Content preview (files only)
            if !file.isDirectory {
                ContentPreviewContainer(file: file)
            }

            if showMetadata {
                // Quick info bar — always visible, acts as a summary
                quickInfoBar

                // Tags — always visible when present
                if !file.tags.isEmpty {
                    tagsBar
                }

                // Expandable full metadata
                if metadataExpanded {
                    MetadataTable(
                        file: file,
                        showingTagMenu: $showingTagMenu,
                        onTagsChanged: onTagsChanged,
                        onRefresh: onRefresh,
                        onPermissionsChanged: onPermissionsChanged
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Expand/collapse toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        metadataExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(metadataExpanded ? "Less Info" : "More Info")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(metadataExpanded ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var quickInfoBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                if file.isDirectory, let count = file.itemCount {
                    LabeledInfo(label: "Items", value: "\(count)")
                } else {
                    LabeledInfo(label: "Size", value: file.size)
                }
                if let modified = file.modified {
                    LabeledInfo(label: "Modified", value: modified)
                }
                LabeledInfo(label: "Kind", value: file.kind)
            }

            HStack(spacing: 12) {
                if let created = file.created {
                    LabeledInfo(label: "Created", value: created)
                }
                if let ext = file.extension_, ext != "--" {
                    LabeledInfo(label: "Extension", value: ext)
                }
                if let accessed = file.accessed {
                    LabeledInfo(label: "Accessed", value: accessed)
                }
            }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var tagsBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Tags")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            FlowLayout(spacing: 4) {
                ForEach(file.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(neutron.tagColor(for: tag))
                            .frame(width: 7, height: 7)
                        Text(tag)
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct LabeledInfo: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Text / Code Preview

private struct TextPreviewView: View {
    let url: URL
    @State private var content = ""
    @State private var loadError: String?
    @State private var isTruncated = false

    var body: some View {
        Group {
            if let error = loadError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.title3).foregroundStyle(.secondary)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if content.isEmpty {
                ProgressView().scaleEffect(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if isTruncated {
                            HStack(spacing: 4) {
                                Image(systemName: "ellipsis").font(.system(size: 8))
                                Text("Truncated — showing first 64 KB").font(.system(size: 8))
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        }
                    }
                    .padding(8)
                }
                .background(.background)
            }
        }
        .task(id: url) { await loadContent() }
    }

    private func loadContent() async {
        content = ""; loadError = nil; isTruncated = false
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .alwaysMapped)
            }.value
            let maxBytes = 65_536
            if data.count > maxBytes { isTruncated = true }
            let preview = data.prefix(maxBytes)
            guard let text = String(data: preview, encoding: .utf8) ?? String(data: preview, encoding: .ascii) else {
                loadError = "Unable to read as text"; return
            }
            content = text
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - PDF Preview

private struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = NSColor.textBackgroundColor
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        guard let doc = PDFDocument(url: url) else { return }
        v.document = doc
        if let first = doc.page(at: 0) { v.go(to: first) }
    }
}

// MARK: - Image Preview

private struct ImagePreviewView: View {
    let url: URL
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                ProgressView().scaleEffect(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: url) { _, _ in load() }
    }

    private func load() {
        nsImage = nil
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { self.nsImage = img }
        }
    }
}

// MARK: - Video Preview

private struct VideoPreviewView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onTapGesture {
                        isPlaying ? player.pause() : player.play()
                        isPlaying.toggle()
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.secondary)
                    Text("Tap to load video").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            p.isMuted = true
            player = p
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Audio Preview

private struct AudioPreviewView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isPlaying ? "waveform" : "waveform.slash")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                    if !editing { seekTo(currentTime) }
                }
                .controlSize(.small)

                HStack {
                    Text(formatTime(currentTime)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTime(duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            Button {
                guard let p = player else { return }
                isPlaying ? p.pause() : p.play()
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    private func setupPlayer() {
        let p = AVPlayer(url: url)
        player = p
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            self.currentTime = time.seconds
        }
        Task {
            if let d = try? await p.currentItem?.asset.load(.duration) {
                await MainActor.run { self.duration = d.seconds }
            }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserver, let p = player {
            p.removeTimeObserver(token)
        }
        player?.pause()
        player = nil
        timeObserver = nil
    }

    private func seekTo(_ t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, !s.isNaN else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - QuickLook Fallback Preview

private struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let v = QLPreviewView(frame: .zero) else { return NSView() }
        v.autostarts = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? QLPreviewView else { return }
        v.previewItem = url as NSURL
    }
}

// MARK: - Metadata Table

private struct MetadataTable: View {
    let file: FilePreviewItem
    @Binding var showingTagMenu: Bool
    var onTagsChanged: ((URL, [String]) -> Void)?
    var onRefresh: (() -> Void)?
    var onPermissionsChanged: ((URL, UInt16) -> Void)?

    @State private var gitTracked = false
    @State private var gitStatus: GitFileStatus?
    @State private var gitRootName: String?

    // Fixed label column width for consistent alignment
    private let labelW: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TableRow(label: "Kind", value: file.kind, labelW: labelW)
                if let ext = file.extension_, ext != "--" {
                    TableRow(label: "Extension", value: ext, labelW: labelW)
                }
                if let mime = file.mimeType, mime != "--" {
                    TableRow(label: "MIME Type", value: mime, labelW: labelW)
                }
                TableRow(label: "Size", value: file.size, labelW: labelW)
                if let sod = file.sizeOnDisk, sod != file.size {
                    TableRow(label: "On Disk", value: sod, labelW: labelW)
                }
                TableRow(label: "Where", value: file.location, labelW: labelW)

                if let created = file.created {
                    TableRow(label: "Created", value: created, labelW: labelW)
                }
                if let modified = file.modified {
                    TableRow(label: "Modified", value: modified, labelW: labelW)
                }
                if let accessed = file.accessed {
                    TableRow(label: "Accessed", value: accessed, labelW: labelW)
                }

                if let count = file.itemCount {
                    TableRow(label: "Items", value: "\(count)", labelW: labelW)
                }

                // ── Permissions grid inline, no header ──
                if file.ownerRead || file.ownerWrite || file.ownerExecute ||
                   file.groupRead || file.groupWrite || file.groupExecute ||
                   file.otherRead || file.otherWrite || file.otherExecute {
                    PermissionGridView(file: file, labelW: labelW, onChanged: onPermissionsChanged)

                    if let mode = file.mode {
                        TableRow(label: "Mode",
                                 value: String(mode, radix: 8),
                                 labelW: labelW,
                                 mono: true)
                    }
                }

                // ── System info inline, no header ──
                let flags = systemFlags(file: file)
                if !flags.isEmpty {
                    TableRow(label: "Flags", value: flags, labelW: labelW)
                }
                if let inode = file.inode {
                    TableRow(label: "Inode",
                             value: "\(inode)",
                             labelW: labelW,
                             mono: true)
                }
                if let device = file.device {
                    TableRow(label: "Device",
                             value: "0x\(String(device, radix: 16))",
                             labelW: labelW,
                             mono: true)
                }
            }
            .padding(.vertical, 8)

            // ── Git (flat, no section header) ──
            if gitTracked {
                Divider().padding(.horizontal, 14)
                HStack(spacing: 0) {
                    if let status = gitStatus {
                        GitBadge(status: status)
                            .padding(.trailing, 6)
                        Text(status.label)
                            .font(.system(size: 11))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .padding(.trailing, 6)
                        Text("No changes")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if let root = gitRootName {
                        Text(root)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .onAppear { Task { await loadGitInfo() } }
        .onChange(of: file.path) { _, _ in Task { await loadGitInfo() } }
    }

    private func systemFlags(file: FilePreviewItem) -> String {
        var parts: [String] = []
        if file.isHidden { parts.append("Hidden") }
        if file.isSymbolicLink { parts.append("Alias / Symlink") }
        if let links = file.hardLinks, links > 1 { parts.append("\(links) hard links") }
        return parts.joined(separator: ", ")
    }

    private func permissionString(file: FilePreviewItem) -> String {
        func c(_ r: Bool, _ w: Bool, _ x: Bool) -> String {
            "\(r ? "r" : "-")\(w ? "w" : "-")\(x ? "x" : "-")"
        }
        let o = c(file.ownerRead, file.ownerWrite, file.ownerExecute)
        let g = c(file.groupRead, file.groupWrite, file.groupExecute)
        let t = c(file.otherRead, file.otherWrite, file.otherExecute)
        return "\(o) \(g) \(t)"
    }

    private func loadGitInfo() async {
        let directory = file.path.deletingLastPathComponent()
        let root = GitStatusProvider.gitRoot(for: directory)
        gitTracked = root != nil
        gitRootName = root?.lastPathComponent

        if let root {
            let statuses = GitStatusProvider.statusInRepo(root: root)
            gitStatus = statuses[file.path.path]
        }
    }
}

// MARK: - Table Row

private struct TableRow: View {
    let label: String
    let value: String
    let labelW: CGFloat
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .trailing)

            Text(value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }
}

// MARK: - Permission Grid (Editable 3×3)

private struct PermissionGridView: View {
    let file: FilePreviewItem
    let labelW: CGFloat
    var onChanged: ((URL, UInt16) -> Void)?

    @State private var ownerR = false
    @State private var ownerW = false
    @State private var ownerX = false
    @State private var groupR = false
    @State private var groupW = false
    @State private var groupX = false
    @State private var otherR = false
    @State private var otherW = false
    @State private var otherX = false

    @State private var showError = false
    @State private var errorMessage = ""
    // Tracks which file's permissions we last synced (by path + mode hash) so we
    // can ignore the spurious .onChange callbacks that fire when syncFromFile()
    // populates @State for the first time.
    @State private var syncStamp: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text("")
                    .frame(width: labelW, alignment: .trailing)
                HStack(spacing: 0) {
                    Text("R").frame(width: 26)
                    Text("W").frame(width: 26)
                    Text("X").frame(width: 26)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)

            PermissionRow(label: "Owner", r: $ownerR, w: $ownerW, x: $ownerX, labelW: labelW, onChange: applyChanges)
            PermissionRow(label: "Group", r: $groupR, w: $groupW, x: $groupX, labelW: labelW, onChange: applyChanges)
            PermissionRow(label: "Other", r: $otherR, w: $otherW, x: $otherX, labelW: labelW, onChange: applyChanges)
        }
        .onAppear(perform: syncFromFile)
        .onChange(of: file.path) { _, _ in syncFromFile() }
        .alert("Could Not Change Permissions", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func syncFromFile() {
        ownerR = file.ownerRead
        ownerW = file.ownerWrite
        ownerX = file.ownerExecute
        groupR = file.groupRead
        groupW = file.groupWrite
        groupX = file.groupExecute
        otherR = file.otherRead
        otherW = file.otherWrite
        otherX = file.otherExecute
        syncStamp = "\(file.path.path):\(modeValue)"
    }

    private var modeValue: UInt16 {
        (ownerR ? 0o400 : 0) | (ownerW ? 0o200 : 0) | (ownerX ? 0o100 : 0) |
        (groupR ? 0o040 : 0) | (groupW ? 0o020 : 0) | (groupX ? 0o010 : 0) |
        (otherR ? 0o004 : 0) | (otherW ? 0o002 : 0) | (otherX ? 0o001 : 0)
    }

    private func applyChanges() {
        let mode = modeValue
        let stamp = "\(file.path.path):\(mode)"
        // Skip if this mode matches the file on disk (initial sync or no-op)
        guard stamp != syncStamp else { return }
        syncStamp = stamp

        guard let callback = onChanged else {
            // No handler provided — try direct chmod as fallback
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: file.path.path
                )
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                syncFromFile() // revert
            }
            return
        }
        callback(file.path, mode)
    }
}

private struct PermissionRow: View {
    let label: String
    @Binding var r: Bool
    @Binding var w: Bool
    @Binding var x: Bool
    let labelW: CGFloat
    var onChange: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .trailing)

            HStack(spacing: 0) {
                Toggle("", isOn: $r)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(width: 26)
                    .onChange(of: r) { _, _ in onChange?() }
                Toggle("", isOn: $w)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(width: 26)
                    .onChange(of: w) { _, _ in onChange?() }
                Toggle("", isOn: $x)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(width: 26)
                    .onChange(of: x) { _, _ in onChange?() }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 1)
    }
}

// MARK: - Git Badge

private struct GitBadge: View {
    let status: GitFileStatus

    var body: some View {
        Text(short)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(status.color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var short: String {
        switch status {
        case .modified: return "M"
        case .staged:   return "A"
        case .untracked: return "?"
        case .conflict: return "!"
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (i, pos) in result.positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxW = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            positions.append(CGPoint(x: x, y: y))
            rowH = max(rowH, sz.height)
            x += sz.width + spacing
        }
        return (positions, CGSize(width: maxW, height: y + rowH))
    }
}

// MARK: - File Type Helpers

private func isTextFile(ext: String) -> Bool {
    ["txt", "rtf", "log", "csv", "tsv", "md", "markdown", "rst", "adoc", "asciidoc",
     "tex", "bib", "nfo", "readme", "msg", "yaml", "yml"].contains(ext)
}

private func isCodeFile(ext: String) -> Bool {
    ["swift", "js", "ts", "jsx", "tsx", "mjs", "cjs", "py", "rb", "c", "cpp", "cxx",
     "cc", "h", "hpp", "hxx", "go", "rs", "java", "kt", "kts", "dart", "sh", "zsh",
     "bash", "fish", "css", "scss", "less", "sass", "html", "htm", "php", "sql",
     "graphql", "gql", "proto", "scala", "clj", "cljs", "cljc", "lua", "hs", "r",
     "m", "mm", "pl", "pm", "tcl", "lisp", "el", "ex", "exs", "vue", "svelte",
     "astro", "zig", "nim", "crystal", "erl", "fs", "fsx", "ml", "sml", "asm", "s",
     "ps1", "bat", "cmd", "awk", "sed", "vim", "toml", "gradle", "cmake", "makefile",
     "dockerfile", "env", "gitignore", "gitattributes", "editorconfig", "conf",
     "cfg", "ini", "json", "xml", "svg"].contains(ext)
}

private func isImageFile(ext: String) -> Bool {
    ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico"].contains(ext)
}

private func isVideoFile(ext: String) -> Bool {
    ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "ts"].contains(ext)
}

private func isAudioFile(ext: String) -> Bool {
    ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "alac", "opus"].contains(ext)
}
