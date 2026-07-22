import SwiftUI

struct PathEditorSheet: View {
    @Binding var path: String
    @Binding var isEditing: Bool
    let baseDirectory: URL
    var onCommit: (String) -> Void

    @State private var suggestions: [PathSuggestion] = []
    @State private var selectedSuggestionIndex: Int = 0
    @FocusState private var isPathFieldFocused: Bool

    private struct PathSuggestion: Identifiable {
        let id = UUID()
        let displayPath: String
        let completionName: String
        let isDirectory: Bool
        let parentDirectoryPath: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Path")
                .font(.headline)

            TextField("/Users/name/Folder", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($isPathFieldFocused)
                .onSubmit {
                    submitPath()
                }

            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                applySuggestion(at: index)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: suggestion.isDirectory ? "folder" : "doc")
                                        .foregroundColor(.secondary)
                                    Text(suggestion.displayPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(index == selectedSuggestionIndex
                                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                                    : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            Text("Tab: autocomplete • ↑/↓: pick suggestion")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    isEditing = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Go") {
                    submitPath()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 500)
        .padding()
        .onAppear {
            isPathFieldFocused = true
            refreshSuggestions()
        }
        .onChange(of: path) { _, _ in
            refreshSuggestions()
        }
        .onKeyPress(.tab) {
            handleTabCompletion()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !suggestions.isEmpty else { return .ignored }
            selectedSuggestionIndex = max(0, selectedSuggestionIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !suggestions.isEmpty else { return .ignored }
            selectedSuggestionIndex = min(suggestions.count - 1, selectedSuggestionIndex + 1)
            return .handled
        }
    }

    static func resolvedURL(for rawInput: String, relativeTo baseDirectory: URL) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("~") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        return baseDirectory.appendingPathComponent(trimmed).standardizedFileURL
    }

    private func submitPath() {
        onCommit(path)
        isEditing = false
    }

    private func refreshSuggestions() {
        suggestions = Self.pathSuggestions(for: path, relativeTo: baseDirectory)
        if selectedSuggestionIndex >= suggestions.count {
            selectedSuggestionIndex = max(0, suggestions.count - 1)
        }
    }

    private func applySuggestion(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        path = suggestions[index].displayPath
        selectedSuggestionIndex = index
        refreshSuggestions()
    }

    private func handleTabCompletion() {
        guard !suggestions.isEmpty else { return }

        let parentDirectories = Set(suggestions.map(\.parentDirectoryPath))
        if parentDirectories.count > 1 {
            applySuggestion(at: selectedSuggestionIndex)
            return
        }

        let fragment = Self.completionFragment(from: path)
        let names = suggestions.map(\.completionName)
        let prefix = Self.longestCommonPrefix(in: names)

        if !fragment.isEmpty, prefix.count > fragment.count {
            path = Self.replacingFragment(in: path, with: prefix)
            refreshSuggestions()
            return
        }

        applySuggestion(at: selectedSuggestionIndex)
    }

    private static func completionFragment(from raw: String) -> String {
        let nsRaw = raw as NSString
        if raw.hasSuffix("/") { return "" }
        return nsRaw.lastPathComponent
    }

    private static func replacingFragment(in raw: String, with replacement: String) -> String {
        if raw.hasSuffix("/") {
            return raw + replacement
        }

        let nsRaw = raw as NSString
        let dir = nsRaw.deletingLastPathComponent

        if dir.isEmpty {
            return replacement
        }

        if dir == "/" {
            return "/" + replacement
        }

        return dir + "/" + replacement
    }

    private static func longestCommonPrefix(in names: [String]) -> String {
        guard var prefix = names.first, !prefix.isEmpty else { return "" }

        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) {
                prefix.removeLast()
                if prefix.isEmpty { return "" }
            }
        }

        return prefix
    }

    private static func pathSuggestions(for rawInput: String, relativeTo baseDirectory: URL) -> [PathSuggestion] {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

        let directoryRaw: String
        let fragment: String

        if raw.hasSuffix("/") {
            directoryRaw = raw
            fragment = ""
        } else {
            let nsRaw = raw as NSString
            directoryRaw = nsRaw.deletingLastPathComponent
            fragment = raw.isEmpty ? "" : nsRaw.lastPathComponent
        }

        let resolvedDirectory: URL
        if raw.isEmpty {
            resolvedDirectory = baseDirectory
        } else if directoryRaw.isEmpty, !raw.hasPrefix("/") && !raw.hasPrefix("~") {
            resolvedDirectory = baseDirectory
        } else if let url = resolvedURL(for: directoryRaw.isEmpty ? raw : directoryRaw, relativeTo: baseDirectory) {
            resolvedDirectory = raw.hasSuffix("/") ? url : url
        } else {
            resolvedDirectory = baseDirectory
        }

        let entries: [URL]
        if ApplicationDirectories.isApplicationsRoot(resolvedDirectory) {
            entries = ApplicationDirectories.mergedImmediateContents(includeHidden: false)
        } else {
            guard let directoryEntries = try? FileManager.default.contentsOfDirectory(
                at: resolvedDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            entries = directoryEntries
        }

        let normalizedFragment = fragment.lowercased()

        return entries
            .filter { entry in
                let name = entry.lastPathComponent.lowercased()
                return normalizedFragment.isEmpty || name.hasPrefix(normalizedFragment)
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let name = entry.lastPathComponent
                let parentDirectory = entry.deletingLastPathComponent().standardizedFileURL

                let defaultPrefix = rawDirectoryPrefix(from: raw, fallbackDirectory: resolvedDirectory, baseDirectory: baseDirectory)
                let dirPrefix: String
                if ApplicationDirectories.isApplicationsRoot(resolvedDirectory) {
                    dirPrefix = displayPathPrefix(for: parentDirectory)
                } else {
                    dirPrefix = defaultPrefix
                }

                var display = dirPrefix

                if !display.isEmpty && !display.hasSuffix("/") && display != "/" {
                    display += "/"
                }

                display += name

                if isDirectory {
                    display += "/"
                }

                return PathSuggestion(
                    displayPath: display,
                    completionName: name,
                    isDirectory: isDirectory,
                    parentDirectoryPath: parentDirectory.path
                )
            }
    }

    private static func rawDirectoryPrefix(from raw: String, fallbackDirectory: URL, baseDirectory: URL) -> String {
        if raw.isEmpty {
            return ""
        }

        if raw.hasSuffix("/") {
            return raw
        }

        let nsRaw = raw as NSString
        let dir = nsRaw.deletingLastPathComponent

        if !dir.isEmpty {
            return dir
        }

        if raw.hasPrefix("/") {
            return "/"
        }

        if raw.hasPrefix("~") {
            return "~"
        }

        if fallbackDirectory.standardizedFileURL == baseDirectory.standardizedFileURL {
            return ""
        }

        return fallbackDirectory.path
    }

    private static func displayPathPrefix(for directory: URL) -> String {
        let standardized = directory.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = standardized.path

        if path == home {
            return "~"
        }

        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }

        return path
    }
}
