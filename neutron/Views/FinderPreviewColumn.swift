import SwiftUI
import Quartz
import QuickLookThumbnailing

struct FinderPreviewColumn: View {
    let file: FilePreviewItem?
    var onRename: ((URL, String) -> Void)?
    var onTagsChanged: ((URL, [String]) -> Void)?
    var onRefresh: (() -> Void)?

    @EnvironmentObject private var fileOps: FileOperations

    @State private var isEditingName = false
    @State private var editingName = ""
    @State private var showingTagMenu = false
    @State private var gitTracked = false
    @State private var gitStatus: GitFileStatus? = nil
    @State private var gitRootName: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let file {
                ScrollView {
                    VStack(spacing: 0) {
                        // Thumbnail
                        thumbnailSection(file: file)
                            .padding(.top, 14)
                            .padding(.horizontal, 14)

                        // Name (editable)
                        nameSection(file: file)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .padding(.bottom, 10)

                        Divider()

                        // Tags
                        tagsSection(file: file)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                        Divider()



                        // Git Info
                        gitInfoSection(file: file)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)

                        Divider()

                        // Quick Info
                        VStack(spacing: 0) {
                            infoRow("Kind", value: file.kind)
                            if let ext = file.extension_, ext != "--" {
                                infoRow("Extension", value: ext)
                            }
                            if let mime = file.mimeType, mime != "--" {
                                infoRow("MIME Type", value: mime)
                            }
                            infoRow("Size", value: file.size)
                            if let sizeOnDisk = file.sizeOnDisk, sizeOnDisk != file.size {
                                infoRow("Size on Disk", value: sizeOnDisk)
                            }
                            infoRow("Location", value: file.location)
                        }
                        .padding(.vertical, 8)

                        Divider()

                        // Dates
                        VStack(spacing: 0) {
                            if let created = file.created {
                                infoRow("Created", value: created)
                            }
                            if let modified = file.modified {
                                infoRow("Modified", value: modified)
                            }
                            if let accessed = file.accessed {
                                infoRow("Accessed", value: accessed)
                            }
                        }
                        .padding(.vertical, 8)

                        // Permissions
                        Divider()
                        permissionsSection(file: file)
                            .padding(.vertical, 8)

                        // Advanced Info
                        if hasAdvancedInfo(file) {
                            Divider()
                            advancedInfoSection(file: file)
                                .padding(.vertical, 8)
                        }


                    }
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func thumbnailSection(file: FilePreviewItem) -> some View {
        VStack(spacing: 6) {
            FinderThumbnailView(url: file.path, isDirectory: file.isDirectory)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            if file.isSymbolicLink {
                Label("Symbolic Link", systemImage: "arrow.forward.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Name (Editable)

    @ViewBuilder
    private func nameSection(file: FilePreviewItem) -> some View {
        if isEditingName {
            TextField("Name", text: $editingName, onCommit: {
                let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != file.name {
                    onRename?(file.path, trimmed)
                }
                isEditingName = false
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, weight: .semibold))
            .onExitCommand {
                isEditingName = false
            }
        } else {
            Text(file.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    editingName = file.name
                    isEditingName = true
                }
                .contextMenu {
                    Button("Rename…") {
                        editingName = file.name
                        isEditingName = true
                    }
                }
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private func tagsSection(file: FilePreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 6) {
                if file.tags.isEmpty {
                    Text("No tags")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(file.tags, id: \.self) { tag in
                            tagChip(tag: tag) {
                                var newTags = file.tags
                                newTags.removeAll { $0 == tag }
                                onTagsChanged?(file.path, newTags)
                            }
                        }
                    }
                }

                tagMenuButton(file: file)
            }
        }
    }

    @ViewBuilder
    private func tagChip(tag: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tagColor(for: tag))
                    .frame(width: 7, height: 7)
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tagColor(for: tag).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tagMenuButton(file: FilePreviewItem) -> some View {
        Menu {
            ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"], id: \.self) { tag in
                Button {
                    var newTags = file.tags
                    if newTags.contains(tag) {
                        newTags.removeAll { $0 == tag }
                    } else {
                        newTags.append(tag)
                    }
                    onTagsChanged?(file.path, newTags)
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
                Button("Remove All Tags", role: .destructive) {
                    onTagsChanged?(file.path, [])
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Git Info

    @ViewBuilder
    private func gitInfoSection(file: FilePreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Git")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if gitTracked {
                if let gitRootName {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(gitRootName)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }

                if let gitStatus {
                    gitStatusBadge(status: gitStatus)
                } else {
                    Label("Clean", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                }
            } else {
                Label("Not tracked", systemImage: "questionmark.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: file.path) {
            await loadGitStatusAsync(for: file)
        }
    }

    @ViewBuilder
    private func gitStatusBadge(status: GitFileStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.primary)
    }

    private func loadGitStatusAsync(for file: FilePreviewItem) async {
        let directory = file.path.deletingLastPathComponent()
        let root = GitStatusProvider.gitRoot(for: directory)
        let tracked = root != nil
        let rootName = root?.lastPathComponent
        var status: GitFileStatus? = nil

        if let root {
            let statuses = await Task.detached(priority: .utility) {
                GitStatusProvider.statusInRepo(root: root)
            }.value
            status = statuses[file.path.path]
        }

        await MainActor.run {
            self.gitTracked = tracked
            self.gitRootName = rootName
            self.gitStatus = status
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private func permissionsSection(file: FilePreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Access")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                accessRow(label: "Owner", read: file.ownerRead, write: file.ownerWrite, execute: file.ownerExecute)
                accessRow(label: "Group", read: file.groupRead, write: file.groupWrite, execute: file.groupExecute)
                accessRow(label: "Other", read: file.otherRead, write: file.otherWrite, execute: file.otherExecute)
            }
        }
    }

    @ViewBuilder
    private func accessRow(label: String, read: Bool, write: Bool, execute: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 52, alignment: .leading)

            HStack(spacing: 12) {
                permissionBadge(icon: "eye", label: "R", active: read)
                permissionBadge(icon: "pencil", label: "W", active: write)
                permissionBadge(icon: "bolt", label: "X", active: execute)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    @ViewBuilder
    private func permissionBadge(icon: String, label: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: active ? icon : "\(icon).slash")
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(active ? .green : .secondary.opacity(0.5))
    }

    // MARK: - Advanced Info

    private func hasAdvancedInfo(_ file: FilePreviewItem) -> Bool {
        file.hardLinks != nil || file.inode != nil || file.device != nil || file.itemCount != nil || file.mode != nil
    }

    @ViewBuilder
    private func advancedInfoSection(file: FilePreviewItem) -> some View {
        VStack(spacing: 0) {
            if let links = file.hardLinks, links > 1 {
                infoRow("Hard Links", value: "\(links)")
            }
            if let itemCount = file.itemCount {
                infoRow("Items", value: "\(itemCount)")
            }
            if let mode = file.mode {
                infoRow("Mode", value: String(mode, radix: 8))
            }
            if let inode = file.inode {
                infoRow("Inode", value: "\(inode)")
            }
            if let device = file.device {
                infoRow("Device", value: "0x\(String(device, radix: 16))")
            }
            if file.isHidden {
                infoRow("Flags", value: "Hidden")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Selection")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Select a file to preview")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

// MARK: - FlowLayout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (positions, CGSize(width: maxWidth, height: totalHeight))
    }
}

// MARK: - Thumbnail

private struct FinderThumbnailView: View {
    let url: URL
    let isDirectory: Bool

    @State private var thumbnail: NSImage?
    @State private var thumbnailLoadID = UUID()

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
                    .padding(20)
            }
        }
        .frame(width: 180, height: 180)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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

        let loadID = UUID()
        thumbnailLoadID = loadID

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            DispatchQueue.main.async { [loadID] in
                guard self.thumbnailLoadID == loadID else { return }
                self.thumbnail = representation?.nsImage
            }
        }
    }
}
