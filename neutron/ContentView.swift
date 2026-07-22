//
//  ContentView.swift
//  neutron
//
//  Created by Dodge1 on 10/31/25.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var fileOps = FileOperations()
    @StateObject private var cloudWorkspace = CloudWorkspaceStore.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedSidebarPath: URL? = FileManager.default.homeDirectoryForCurrentUser
    @State private var viewMode: FileBrowserView.ViewMode = .list
    @AppStorage("showHiddenByDefault") private var showHiddenByDefault = false
    @AppStorage("defaultPath") private var defaultPath: String = "Home"
    @State private var showHiddenFiles = false

    // Navigation history
    @State private var navigationHistory: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    @State private var historyIndex: Int = 0

    // Active pane path (tracks the left pane's current directory)
    @State private var activePanePath: URL = FileManager.default.homeDirectoryForCurrentUser

    // Search
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var cloudSearchResults: [CloudSearchResult] = []
    @State private var cloudSearchTask: Task<Void, Never>?

    // Creation
    @State private var showNewFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var showNewFileAlert: Bool = false
    @State private var newFileName: String = ""

    // Share
    @State private var shareItems: [URL] = []
    @State private var showSharePicker: Bool = false

    // Command Palette
    @State private var showCommandPalette: Bool = false

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < navigationHistory.count - 1 }

    private var resolvedDefaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch defaultPath {
        case "Most recent", "Recents":
            return VirtualLocation.recentsURL
        case "Home":
            return home
        case "Documents":
            return home.appendingPathComponent("Documents")
        case "Downloads":
            return home.appendingPathComponent("Downloads")
        case "Desktop":
            return home.appendingPathComponent("Desktop")
        default:
            return home
        }
    }

    private var navigationView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedPath: $selectedSidebarPath)
                .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 220)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if isSearching {
                searchHeader
            }

            DualPaneView(
                viewMode: $viewMode,
                showHiddenFiles: $showHiddenFiles,
                initialPath: selectedSidebarPath ?? resolvedDefaultPath,
                selectedSidebarPath: $selectedSidebarPath,
                activePanePath: $activePanePath,
                searchText: searchText
            )
        }
    }

    @ViewBuilder
    private var searchHeader: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search files…", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Button {
                searchText = ""
                isSearching = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))

        if cloudWorkspace.model.unifiedSearchEnabled,
           !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CloudSearchInlineResultsView(
                query: searchText,
                results: cloudSearchResults,
                onOpen: { url in
                    selectedSidebarPath = url
                    activePanePath = url
                }
            )
            .frame(maxHeight: 220)
        }

        Divider()
    }

    @ToolbarContentBuilder
    private var mainToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "nav", placement: .navigation) {
            Section {
                Button("Back", systemImage: "chevron.left") {
                    goBack()
                }
                .disabled(!canGoBack)

                Button("Forward", systemImage: "chevron.right") {
                    goForward()
                }
                .disabled(!canGoForward)
            }
        }

        ToolbarItem(id: "toggleHidden") {
            Button {
                showHiddenFiles.toggle()
            } label: {
                Image(systemName: showHiddenFiles ? "eye.fill" : "eye")
            }
            .help("Show Hidden Files")
        }
        ToolbarItem(id: "delete") {
            Button("Delete", systemImage: "trash", role: .destructive) {
                NotificationCenter.default.post(
                    name: .trashSelectedFiles,
                    object: nil,
                    userInfo: ["directory": activePanePath]
                )
            }
        }
        ToolbarItem(id: "search") {
            Button("Search", systemImage: "magnifyingglass") {
                isSearching.toggle()
                if !isSearching {
                    searchText = ""
                }
            }
        }
        ToolbarItem(id: "share") {
            Button("Share", systemImage: "square.and.arrow.up") {
                NotificationCenter.default.post(
                    name: .shareSelectedFiles,
                    object: nil
                )
            }
        }
    }

    private var scaffold: some View {
        navigationView
            .frame(minWidth: 900, minHeight: 620)
            .toolbar(removing: .sidebarToggle)
            .toolbarRole(.editor)
            .environmentObject(fileOps)
            .toolbar(id: "main-window-toolbar") { mainToolbar }
            .sheet(isPresented: $showNewFolderAlert) {
                NewFolderSheet(
                    folderName: $newFolderName,
                    isPresented: $showNewFolderAlert
                ) { name in
                    _ = fileOps.createNewFolder(in: activePanePath, name: name)
                    NotificationCenter.default.post(name: .refreshFiles, object: nil)
                }
            }
            .sheet(isPresented: $showNewFileAlert) {
                NewFileSheet(
                    fileName: $newFileName,
                    isPresented: $showNewFileAlert
                ) { name in
                    _ = fileOps.createNewFile(in: activePanePath, name: name)
                    NotificationCenter.default.post(name: .refreshFiles, object: nil)
                }
            }
            .onAppear {
                showHiddenFiles = showHiddenByDefault
                let initialPath = resolvedDefaultPath
                selectedSidebarPath = initialPath
                activePanePath = initialPath
                navigationHistory = [initialPath]
                historyIndex = 0
                refreshCloudSearchResults()
            }
    }

    private func bindHandlers<Content: View>(to view: Content) -> some View {
        bindNavigationHandlers(to: bindCreationHandlers(to: view))
    }

    private func bindCreationHandlers<Content: View>(to view: Content) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for: .createNewFolder)) { _ in
                newFolderName = ""
                showNewFolderAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .createNewFile)) { _ in
                newFileName = ""
                showNewFileAlert = true
            }
    }

    private func bindNavigationHandlers<Content: View>(to view: Content) -> some View {
        view
            .onChange(of: activePanePath) { _, newPath in
                pushHistory(newPath)
            }
            .onChange(of: selectedSidebarPath) { _, newPath in
                // Sidebar selection flows through activePanePath so its onChange
                // handles history — avoid double-pushing the same path.
                if let path = newPath, path != activePanePath {
                    activePanePath = path
                }
            }
            .onChange(of: searchText) { _, _ in
                refreshCloudSearchResults()
            }
            .onChange(of: isSearching) { _, _ in
                refreshCloudSearchResults()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateBack)) { _ in
                goBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateForward)) { _ in
                goForward()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
                isSearching.toggle()
                if !isSearching {
                    searchText = ""
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goHome)) { _ in
                let home = FileManager.default.homeDirectoryForCurrentUser
                selectedSidebarPath = home
                activePanePath = home
            }
            .onReceive(NotificationCenter.default.publisher(for: .goDesktop)) { _ in
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                selectedSidebarPath = desktop
                activePanePath = desktop
            }
            .onReceive(NotificationCenter.default.publisher(for: .goDownloads)) { _ in
                let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                selectedSidebarPath = downloads
                activePanePath = downloads
            }
            .onReceive(NotificationCenter.default.publisher(for: .goDocuments)) { _ in
                let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
                selectedSidebarPath = documents
                activePanePath = documents
            }
    }


    var body: some View {
        bindHandlers(to: scaffold)
            .overlay {
                if showCommandPalette {
                    ZStack {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                            .onTapGesture {
                                showCommandPalette = false
                            }

                        VStack {
                            CommandPaletteView(isPresented: $showCommandPalette)
                                .padding(.top, 60)
                            Spacer()
                        }
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: showCommandPalette)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
                showCommandPalette.toggle()
            }
    }

    // MARK: - Navigation History

    private func pushHistory(_ url: URL) {
        guard navigationHistory.isEmpty || navigationHistory[historyIndex] != url else { return }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((historyIndex + 1)...)
        }
        navigationHistory.append(url)
        historyIndex = navigationHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let target = navigationHistory[historyIndex]
        selectedSidebarPath = target
        activePanePath = target
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let target = navigationHistory[historyIndex]
        selectedSidebarPath = target
        activePanePath = target
    }

    private func refreshCloudSearchResults() {
        cloudSearchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearching,
              cloudWorkspace.model.unifiedSearchEnabled,
              !query.isEmpty else {
            cloudSearchResults = []
            return
        }

        cloudSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            cloudSearchResults = Array(cloudWorkspace.unifiedSearchResults(for: query).prefix(20))
        }
    }

}

// MARK: - NewFolderSheet

struct CloudSearchInlineResultsView: View {
    let query: String
    let results: [CloudSearchResult]
    var onOpen: (URL) -> Void

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Cloud Results", systemImage: "icloud")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(results.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if results.isEmpty {
                Text("No cloud results for \"\(query)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(results) { result in
                    Button {
                        onOpen(result.targetURL)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title)
                                .lineLimit(1)
                            Text(result.pathDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(result.accountName)
                                Text("•")
                                Text(result.kind)
                                if let sizeBytes = result.sizeBytes {
                                    Text("•")
                                    Text(byteFormatter.string(fromByteCount: sizeBytes))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct NewFolderSheet: View {
    @Binding var folderName: String
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onCreate(name)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}

struct NewFileSheet: View {
    @Binding var fileName: String
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New File")
                .font(.headline)
            TextField("File name", text: $fileName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onCreate(name)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
