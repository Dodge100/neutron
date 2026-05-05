import SwiftUI
import AppKit

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    private var filteredCommands: [PaletteCommand] {
        let all = PaletteCommand.allCommands
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit {
                        executeSelected()
                    }

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                            CommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                executeSelected()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, newIndex in
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }

            if filteredCommands.isEmpty {
                Text("No matching commands")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding()
            }
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            isFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredCommands.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func executeSelected() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        filteredCommands[selectedIndex].action()
        isPresented = false
    }
}

private struct CommandRow: View {
    let command: PaletteCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .frame(width: 20)
                .foregroundColor(isSelected ? .white : Color(nsColor: .controlAccentColor))

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .primary)
                Text(command.category)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }

            Spacer()

            if let shortcut = command.shortcutDisplay {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlAccentColor) : Color.clear)
        )
        .padding(.horizontal, 4)
    }
}

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let category: String
    let shortcutDisplay: String?
    let action: () -> Void

    static var allCommands: [PaletteCommand] {
        let manager = ShortcutManager.shared
        var commands: [PaletteCommand] = []

        let actionEntries: [(ShortcutAction, String, String)] = [
            (.newTab, "plus.square", "Tabs"),
            (.closeTab, "xmark.square", "Tabs"),
            (.splitPaneHorizontal, "rectangle.split.2x1", "Panes"),
            (.splitPaneVertical, "rectangle.split.1x2", "Panes"),
            (.newFolder, "folder.badge.plus", "File"),
            (.duplicate, "doc.on.doc", "File"),
            (.delete, "trash", "File"),
            (.copy, "doc.on.doc", "Edit"),
            (.paste, "doc.on.clipboard", "Edit"),
            (.cut, "scissors", "Edit"),
            (.selectAll, "checkmark.circle", "Edit"),
            (.search, "magnifyingglass", "Search"),
            (.goBack, "chevron.left", "Navigation"),
            (.goForward, "chevron.right", "Navigation"),
            (.goUp, "arrow.up", "Navigation"),
            (.goHome, "house", "Navigation"),
            (.goDesktop, "desktopcomputer", "Navigation"),
            (.goDownloads, "arrow.down.circle", "Navigation"),
            (.goDocuments, "doc.text", "Navigation"),
            (.toggleHidden, "eye", "View"),
            (.quickLook, "eye.fill", "View"),
            (.getInfo, "info.circle", "File"),
            (.rename, "pencil", "File"),
            (.openTerminal, "terminal", "Tools"),
            (.refresh, "arrow.clockwise", "View"),
            (.toggleRightPane, "sidebar.right", "Panes"),
            (.viewAsIcons, "square.grid.2x2", "View"),
            (.viewAsList, "list.bullet", "View"),
            (.viewAsColumns, "rectangle.split.3x1", "View"),
        ]

        for (action, icon, category) in actionEntries {
            let shortcut = manager.shortcut(for: action)
            commands.append(PaletteCommand(
                title: action.rawValue,
                icon: icon,
                category: category,
                shortcutDisplay: shortcut?.displayString,
                action: { action.trigger() }
            ))
        }

        // Downloads
        commands.append(PaletteCommand(
            title: "Open Downloads",
            icon: "arrow.down.circle",
            category: "Tools",
            shortcutDisplay: "⌥⌘J",
            action: { NotificationCenter.default.post(name: .showDownloadsPanel, object: nil) }
        ))

        commands.append(PaletteCommand(
            title: "Go to Folder…",
            icon: "folder",
            category: "Navigation",
            shortcutDisplay: "⇧⌘G",
            action: { NotificationCenter.default.post(name: .goToFolder, object: nil) }
        ))

        return commands
    }
}
