import SwiftUI

struct PathBarView: View {
    @Binding var currentPath: URL
    @State private var isEditing = false
    @State private var editedPath: String = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Home button
                Button(action: goToHome) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to Home")
                .padding(.trailing, 4)

                if !pathComponents.isEmpty {
                    chevronSeparator
                }

                // Path components
                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    PathComponentButton(
                        name: component.name,
                        url: component.url,
                        isLast: index == pathComponents.count - 1,
                        onNavigate: { url in currentPath = url }
                    )

                    if index < pathComponents.count - 1 {
                        chevronSeparator
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .contextMenu {
            contextMenuContent
        }
        .sheet(isPresented: $isEditing) {
            PathEditorSheet(
                path: $editedPath,
                isEditing: $isEditing,
                baseDirectory: currentPath
            ) { newPath in
                guard let url = PathEditorSheet.resolvedURL(for: newPath, relativeTo: currentPath),
                      FileManager.default.fileExists(atPath: url.path) else {
                    return
                }
                currentPath = url
            }
        }
    }

    // MARK: - Chevron Separator

    private var chevronSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Go to Folder…") {
            isEditing = true
            editedPath = currentPath.path
        }
        .keyboardShortcut("G", modifiers: [.command, .shift])

        Divider()

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(currentPath.path, forType: .string)
        }
        .keyboardShortcut("C", modifiers: [.command, .option])

        Button("Copy Path as Finder URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(currentPath.absoluteString, forType: .string)
        }

        Divider()

        Button("Open in Terminal") {
            openTerminal()
        }
        .keyboardShortcut("T", modifiers: [.command, .option])

        Button("Open in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: currentPath.path)
        }
        .keyboardShortcut("F", modifiers: [.command, .option])
    }

    // MARK: - Path Components

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

    // MARK: - Actions

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

// MARK: - Path Component Button

struct PathComponentButton: View {
    let name: String
    let url: URL
    var isLast: Bool = false
    var onNavigate: (URL) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            Button(name) {
                onNavigate(url)
            }
            .keyboardShortcut(.defaultAction)

            if !siblingDirectories.isEmpty {
                Divider()

                ForEach(siblingDirectories.prefix(15), id: \.self) { sibling in
                    Button {
                        onNavigate(sibling)
                    } label: {
                        Label(sibling.lastPathComponent, systemImage: "folder")
                    }
                }

                if siblingDirectories.count > 15 {
                    Divider()
                    Text("\(siblingDirectories.count - 15) more folders…")
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(name)
                .font(.system(size: 11, weight: isLast ? .medium : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
                        )
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
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

// MARK: - Preview

#Preview {
    PathBarView(currentPath: .constant(URL(fileURLWithPath: NSHomeDirectory())))
        .frame(width: 600, height: 30)
}
