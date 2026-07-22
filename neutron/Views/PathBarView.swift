import SwiftUI

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
            Button("Open Path…") {
                isEditing = true
                editedPath = ""
            }
            Divider()
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
            Button("Go to Folder…") {
                isEditing = true
                editedPath = currentPath.path
            }
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
