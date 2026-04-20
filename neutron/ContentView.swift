//
//  ContentView.swift
//  neutron
//
//  Created by Dodge1 on 10/31/25.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var fileOps = FileOperations()

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

    // New Folder
    @State private var showNewFolderAlert: Bool = false
    @State private var newFolderName: String = ""

    // Share
    @State private var shareItems: [URL] = []
    @State private var showSharePicker: Bool = false

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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedPath: $selectedSidebarPath)
                .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if isSearching {
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
                    Divider()
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
        .toolbar(removing: .sidebarToggle)
        .environmentObject(fileOps)
        .onChange(of: activePanePath) { _, newPath in
            pushHistory(newPath)
        }
        .onChange(of: selectedSidebarPath) { _, newPath in
            if let path = newPath {
                pushHistory(path)
            }
        }
        .toolbar(id: "toolbar") {
            ToolbarItem(id: "nav", placement: .navigation) {
                Section {
                    Button("Back", systemImage: "chevron.left") {
                        goBack()
                    }
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)

                    Button("Forward", systemImage: "chevron.right") {
                        goForward()
                    }
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                }
            }
            
            ToolbarItem(id: "space") {
                Spacer()
            }
            ToolbarItem(id: "toggleHidden") {
                Toggle(isOn: $showHiddenFiles) {
                    Image(systemName: "eye")
                }
                .help("Show Hidden Files")
            }
            ToolbarItem(id: "newFolder") {
                Button("New Folder", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    showNewFolderAlert = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            ToolbarItem(id: "delete") {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    NotificationCenter.default.post(
                        name: .trashSelectedFiles,
                        object: nil,
                        userInfo: ["directory": activePanePath]
                    )
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            ToolbarItem(id: "search") {
                Button("Search", systemImage: "magnifyingglass") {
                    isSearching.toggle()
                    if !isSearching {
                        searchText = ""
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            ToolbarItem(id: "share") {
                Button("Share", systemImage: "square.and.arrow.up") {
                    NotificationCenter.default.post(
                        name: .shareSelectedFiles,
                        object: nil
                    )
                }
            }
            ToolbarItem(id: "transfers") {
                Button("Transfers", systemImage: "arrow.down.circle") {
                    openWindow(id: "downloads")
                }
                .help("Open Transfers")
            }
        }
        .sheet(isPresented: $showNewFolderAlert) {
            NewFolderSheet(
                folderName: $newFolderName,
                isPresented: $showNewFolderAlert
            ) { name in
                _ = fileOps.createNewFolder(in: activePanePath, name: name)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewFolder)) { _ in
            newFolderName = ""
            showNewFolderAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateBack)) { _ in
            goBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateForward)) { _ in
            goForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .goHome)) { _ in
            selectedSidebarPath = FileManager.default.homeDirectoryForCurrentUser
        }
        .onReceive(NotificationCenter.default.publisher(for: .goDesktop)) { _ in
            selectedSidebarPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        }
        .onReceive(NotificationCenter.default.publisher(for: .goDownloads)) { _ in
            selectedSidebarPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        .onReceive(NotificationCenter.default.publisher(for: .goDocuments)) { _ in
            selectedSidebarPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDownloadsPanel)) { notification in
            handleTransferWindowRequest(notification, replayName: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showVideoDownload)) { notification in
            handleTransferWindowRequest(notification, replayName: .showVideoDownload)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTorrentMagnet)) { notification in
            handleTransferWindowRequest(notification, replayName: .showTorrentMagnet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTorrentFilePicker)) { notification in
            handleTransferWindowRequest(notification, replayName: .showTorrentFilePicker)
        }
        .onAppear {
            showHiddenFiles = showHiddenByDefault
            let initialPath = resolvedDefaultPath
            selectedSidebarPath = initialPath
            activePanePath = initialPath
            if navigationHistory.isEmpty {
                navigationHistory = [initialPath]
                historyIndex = 0
            } else {
                navigationHistory = [initialPath]
                historyIndex = 0
            }
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
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let target = navigationHistory[historyIndex]
        selectedSidebarPath = target
    }

    private func handleTransferWindowRequest(_ notification: Notification, replayName: Notification.Name?) {
        if notification.userInfo?["replay"] as? Bool == true {
            return
        }

        openWindow(id: "downloads")

        guard let replayName else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: replayName, object: nil, userInfo: ["replay": true])
        }
    }
}

// MARK: - NewFolderSheet

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

// MARK: - Preview

#Preview {
    ContentView()
}
