import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

enum PaneAxis: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .horizontal: return "rectangle.split.2x1"
        case .vertical: return "rectangle.split.1x2"
        }
    }

    var title: String { rawValue.capitalized }
}

enum WorkspaceLayoutPreset: String, Codable, CaseIterable, Identifiable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
    case grid = "Grid"

    var id: String { rawValue }
}

struct FileTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var path: URL

    init(id: UUID = UUID(), title: String, path: URL) {
        self.id = id
        self.title = title
        self.path = path
    }
}

struct TabDragPayload: Codable, Hashable {
    let tabID: UUID
    let sourcePaneID: UUID
    let title: String
    let path: String

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString()
    }

    static func decode(_ raw: String) -> TabDragPayload? {
        guard let data = Data(base64Encoded: raw) else { return nil }
        return try? JSONDecoder().decode(TabDragPayload.self, from: data)
    }
}

struct PaneState: Identifiable, Equatable {
    let id: UUID
    var tabs: [FileTab]
    var selectedTabId: UUID?
    var viewMode: FileBrowserView.ViewMode
    var previewItem: FilePreviewItem?

    init(
        id: UUID = UUID(),
        path: URL = URL(fileURLWithPath: NSHomeDirectory()),
        viewMode: FileBrowserView.ViewMode = .list
    ) {
        let title = VirtualLocation.displayName(for: path)
        let tab = FileTab(title: title, path: path)
        self.id = id
        self.tabs = [tab]
        self.selectedTabId = tab.id
        self.viewMode = viewMode
        self.previewItem = nil
    }

    var currentPath: URL {
        get {
            tabs.first(where: { $0.id == selectedTabId })?.path
                ?? tabs.first?.path
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set {
            guard let index = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
            tabs[index].path = newValue
            tabs[index].title = VirtualLocation.displayName(for: newValue)
        }
    }

    mutating func navigate(to path: URL) {
        currentPath = path
    }

    mutating func addTab(path: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        let title = VirtualLocation.displayName(for: path)
        let tab = FileTab(title: title, path: path)
        tabs.append(tab)
        selectedTabId = tab.id
    }

    mutating func closeSelectedTab() -> Bool {
        guard let selectedTabId,
              let index = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return false }

        tabs.remove(at: index)

        if tabs.isEmpty {
            self.selectedTabId = nil
            return true
        } else {
            self.selectedTabId = tabs[min(index, tabs.count - 1)].id
        }

        return false
    }

    mutating func selectTab(_ tab: FileTab) {
        selectedTabId = tab.id
    }
}

indirect enum PaneNode: Identifiable, Equatable {
    case pane(UUID)
    case split(id: UUID, axis: PaneAxis, children: [PaneNode])

    var id: UUID {
        switch self {
        case .pane(let id): return id
        case .split(let id, _, _): return id
        }
    }

    func containsPane(_ paneID: UUID) -> Bool {
        switch self {
        case .pane(let id):
            return id == paneID
        case .split(_, _, let children):
            return children.contains { $0.containsPane(paneID) }
        }
    }

    func allPaneIDs() -> [UUID] {
        switch self {
        case .pane(let id):
            return [id]
        case .split(_, _, let children):
            return children.flatMap { $0.allPaneIDs() }
        }
    }

    func siblingCount(for paneID: UUID, axis: PaneAxis) -> Int? {
        switch self {
        case .pane(let id):
            return id == paneID ? nil : nil
        case .split(_, let currentAxis, let children):
            if currentAxis == axis, children.contains(where: { $0.containsPane(paneID) }) {
                return children.count
            }
            for child in children {
                if let count = child.siblingCount(for: paneID, axis: axis) {
                    return count
                }
            }
            return nil
        }
    }
}


struct DualPaneView: View {
    @Binding var viewMode: FileBrowserView.ViewMode
    @Binding var showHiddenFiles: Bool
    var initialPath: URL?
    @Binding var selectedSidebarPath: URL?
    @Binding var activePanePath: URL
    var searchText: String

    @EnvironmentObject var fileOps: FileOperations
    @StateObject private var cloudWorkspace = CloudWorkspaceStore.shared

    @AppStorage("syncPaneViewModes") private var syncPaneViewModes = false
    @AppStorage("previewColumnWidth") private var previewColumnWidth: Double = 300

    @State private var paneStates: [UUID: PaneState]
    @State private var layoutTree: PaneNode
    @State private var focusedPaneID: UUID?
    @State private var sharedPreviewItem: FilePreviewItem?

    init(
        viewMode: Binding<FileBrowserView.ViewMode>,
        showHiddenFiles: Binding<Bool>,
        initialPath: URL? = nil,
        selectedSidebarPath: Binding<URL?>? = nil,
        activePanePath: Binding<URL>? = nil,
        searchText: String = ""
    ) {
        self._viewMode = viewMode
        self._showHiddenFiles = showHiddenFiles
        self.initialPath = initialPath
        self._selectedSidebarPath = selectedSidebarPath ?? .constant(nil)
        self._activePanePath = activePanePath ?? .constant(FileManager.default.homeDirectoryForCurrentUser)
        self.searchText = searchText

        let path = initialPath ?? FileManager.default.homeDirectoryForCurrentUser
        let firstPane = PaneState(path: path, viewMode: viewMode.wrappedValue)
        let secondPane = PaneState(path: path, viewMode: viewMode.wrappedValue)

        let initialPaneStates: [UUID: PaneState] = [
            firstPane.id: firstPane,
            secondPane.id: secondPane
        ]

        let initialLayoutTree = DualPaneView.defaultLayout(
            for: [firstPane.id, secondPane.id],
            preset: .horizontal
        )

        self._paneStates = State(initialValue: initialPaneStates)
        self._layoutTree = State(initialValue: initialLayoutTree)
        self._focusedPaneID = State(initialValue: firstPane.id)
        self._sharedPreviewItem = State(initialValue: nil)
    }

    private var focusedPane: PaneState? {
        guard let focusedPaneID else { return nil }
        return paneStates[focusedPaneID]
    }

    private func canAddPane(axis: PaneAxis) -> Bool {
        focusedPaneID != nil
    }

    private var pathBarEnabled: Bool {
        UserDefaults.standard.object(forKey: "showPathBarInPanes") as? Bool ?? true
    }

    private var statusBarEnabled: Bool {
        UserDefaults.standard.object(forKey: "showStatusBarInPanes") as? Bool ?? true
    }

    var body: some View {
        let baseView = workspaceView
            .toolbar(id: "workspace-toolbar") {
                toolbarContent
            }
            .onAppear(perform: handleAppear)
            .onChange(of: selectedSidebarPath) { _, newPath in
                handleSidebarSelectionChange(newPath)
            }

        let tabView = baseView
            .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
                handleNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
                handleCloseTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleHiddenFiles)) { _ in
                showHiddenFiles.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToParentFolder)) { _ in
                handleGoToParentFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToFolder)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.goToFolder)
            }

        let commandView = tabView
            .onReceive(NotificationCenter.default.publisher(for: .duplicateSelectedFiles)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.duplicateSelectedFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .copySelectedFiles)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.copySelectedFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cutSelectedFiles)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.cutSelectedFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteFiles)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.pasteFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllFiles)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.selectAllFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickLookSelected)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.quickLookSelected)
            }
            .onReceive(NotificationCenter.default.publisher(for: .getInfoSelected)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.getInfoSelected)
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameSelected)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.renameSelected)
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshFiles)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.refreshFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInTerminal)) { notification in
                guard notification.object == nil else { return }
                postFocusedPaneCommand(.openInTerminal)
            }

        return commandView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onReceive(NotificationCenter.default.publisher(for: .toggleRightPane)) { _ in
                focusAdjacentPane()
            }
            .onReceive(NotificationCenter.default.publisher(for: .setViewMode)) { notification in
                handleSetViewMode(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .splitPaneHorizontal)) { _ in
                guard let focusedPaneID else { return }
                addPane(nextTo: focusedPaneID, axis: .horizontal)
            }
            .onReceive(NotificationCenter.default.publisher(for: .splitPaneVertical)) { _ in
                guard let focusedPaneID else { return }
                addPane(nextTo: focusedPaneID, axis: .vertical)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectTabAtIndex)) { notification in
                guard let index = notification.object as? Int else { return }
                selectTab(at: index, inOtherPane: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectTabAtIndexInOtherPane)) { notification in
                guard let index = notification.object as? Int else { return }
                selectTab(at: index, inOtherPane: true)
            }
            .onChange(of: focusedPaneID) { _, _ in
                syncFocusedPaneState()
            }
    }

    @ViewBuilder
    private var workspaceView: some View {
        GeometryReader { proxy in
            let minMainWidth: CGFloat = 520
            let minPreviewWidth: CGFloat = 220
            let maxPreviewWidth: CGFloat = 460

            let totalWidth = proxy.size.width
            let availablePreviewMax = max(0, totalWidth - minMainWidth)
            let effectivePreviewWidth = min(
                max(CGFloat(previewColumnWidth), minPreviewWidth),
                min(maxPreviewWidth, availablePreviewMax)
            )
            let canShowPreview = availablePreviewMax >= minPreviewWidth

            HStack(spacing: 0) {
                PaneWorkspaceNodeView(
                    node: $layoutTree,
                    paneStates: $paneStates,
                    focusedPaneID: $focusedPaneID,
                    showHiddenFiles: $showHiddenFiles,
                    selectedSidebarPath: $selectedSidebarPath,
                    activePanePath: $activePanePath,
                    searchText: searchText,
                    pathBarEnabled: pathBarEnabled,
                    statusBarEnabled: statusBarEnabled,
                    cloudWorkspace: cloudWorkspace.model,
                    canAddPane: true,
                    canClosePane: paneStates.count > 1,
                    showFocusRing: paneStates.count > 1,
                    onViewModeChange: handleViewModeChange,
                    onAddSiblingPane: addPane(nextTo:axis:),
                    onRemovePane: removePane(_:),
                    onPreviewSelectionChange: handlePreviewSelectionChange(for:item:),
                    onDropTab: handleDroppedTab(_:into:targetIndex:)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if canShowPreview {
                    Divider()
                    FinderPreviewColumn(
                        file: paneStates[focusedPaneID ?? UUID()]?.previewItem,
                        onRename: handlePreviewRename,
                        onTagsChanged: handlePreviewTagsChanged,
                        onRefresh: handlePreviewRefresh
                    )
                    .environmentObject(fileOps)
                    .frame(width: effectivePreviewWidth)
                    .onAppear {
                        previewColumnWidth = Double(effectivePreviewWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.16), value: canShowPreview)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "pane-management", placement: .navigation) {
            Menu {
                Section("Add Pane") {
                    Button("Split Horizontally") {
                        if let focusedPaneID {
                            addPane(nextTo: focusedPaneID, axis: .horizontal)
                        }
                    }
                    .disabled(!canAddPane(axis: .horizontal))

                    Button("Split Vertically") {
                        if let focusedPaneID {
                            addPane(nextTo: focusedPaneID, axis: .vertical)
                        }
                    }
                    .disabled(!canAddPane(axis: .vertical))
                }

                Divider()

                Section("Layout") {
                    Button("Horizontal") {
                        rebuildWorkspace(for: .horizontal)
                    }

                    Button("Vertical") {
                        rebuildWorkspace(for: .vertical)
                    }

                    Button("Grid") {
                        rebuildWorkspace(for: .grid)
                    }
                }

                Divider()

                if paneStates.count > 1 {
                    Button("Close Current Pane", role: .destructive) {
                        if let focusedPaneID {
                            removePane(focusedPaneID)
                        }
                    }
                    .disabled(focusedPaneID == nil)
                }

                Text("\(paneStates.count) Pane\(paneStates.count == 1 ? "" : "s")")
            } label: {
                Image(systemName: "square.split.2x2")
            }
            .help("Manage Panes")
        }

        ToolbarItem(id: "add-item", placement: .primaryAction) {
            Menu {
                Button("File") {
                    NotificationCenter.default.post(name: .createNewFile, object: nil)
                }

                Button("Folder") {
                    NotificationCenter.default.post(name: .createNewFolder, object: nil)
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add File or Folder")
        }

        ToolbarItem(id: "view-mode-icon", placement: .primaryAction) {
            Button {
                setFocusedPaneViewMode(.icon)
            } label: {
                Image(systemName: FileBrowserView.ViewMode.icon.icon)
                    .symbolVariant(focusedPane?.viewMode == .icon ? .fill : .none)
            }
            .disabled(focusedPaneID == nil)
            .help("Icon View")
        }

        ToolbarItem(id: "view-mode-list", placement: .primaryAction) {
            Button {
                setFocusedPaneViewMode(.list)
            } label: {
                Image(systemName: FileBrowserView.ViewMode.list.icon)
                    .symbolVariant(focusedPane?.viewMode == .list ? .fill : .none)
            }
            .disabled(focusedPaneID == nil)
            .help("List View")
        }

        ToolbarItem(id: "view-mode-column", placement: .primaryAction) {
            Button {
                setFocusedPaneViewMode(.column)
            } label: {
                Image(systemName: FileBrowserView.ViewMode.column.icon)
                    .symbolVariant(focusedPane?.viewMode == .column ? .fill : .none)
            }
            .disabled(focusedPaneID == nil)
            .help("Column View")
        }
    }

    private func setFocusedPaneViewMode(_ mode: FileBrowserView.ViewMode) {
        guard let focusedPaneID else { return }
        handleViewModeChange(for: focusedPaneID, to: mode)
    }

    private func handleViewModeChange(for paneID: UUID, to newMode: FileBrowserView.ViewMode) {
        if syncPaneViewModes {
            for id in paneStates.keys {
                paneStates[id]?.viewMode = newMode
            }
        } else {
            paneStates[paneID]?.viewMode = newMode
        }

        if focusedPaneID == paneID || syncPaneViewModes {
            viewMode = newMode
        }
    }

    private func navigatePane(_ paneID: UUID, to path: URL) {
        guard paneStates[paneID] != nil else { return }
        paneStates[paneID]?.navigate(to: path)
        if focusedPaneID == paneID {
            activePanePath = path
        }
    }

    private func handleAppear() {
        syncFocusedPaneState()
    }

    private func handleSidebarSelectionChange(_ newPath: URL?) {
        guard let path = newPath, let focusedPaneID else { return }
        navigatePane(focusedPaneID, to: path)
        activePanePath = path
    }

    private func handleNewTab() {
        guard let focusedPaneID else { return }
        paneStates[focusedPaneID]?.addTab(path: paneStates[focusedPaneID]?.currentPath ?? activePanePath)
        paneStates[focusedPaneID]?.previewItem = nil
        syncFocusedPaneState()
    }

private func handleCloseTab() {
        guard let focusedPaneID else { return }
 
        guard var pane = paneStates[focusedPaneID] else { return }
 
        if pane.tabs.count <= 1 {
            if paneStates.count > 1 {
                removePane(focusedPaneID)
            } else {
                let homePath = FileManager.default.homeDirectoryForCurrentUser
                pane.tabs = [FileTab(title: VirtualLocation.displayName(for: homePath), path: homePath)]
                pane.selectedTabId = pane.tabs.first?.id
                paneStates[focusedPaneID] = pane
                navigatePane(focusedPaneID, to: homePath)
            }
            return
        }
 
        _ = pane.closeSelectedTab()
        pane.previewItem = nil
        paneStates[focusedPaneID] = pane
        syncFocusedPaneState()
    }

    private func handleGoToParentFolder() {
        guard let focusedPaneID,
              let currentPath = paneStates[focusedPaneID]?.currentPath else { return }
        if currentPath.scheme == "neutron-cloud" || currentPath.scheme == "neutron-s3" {
            if let parent = cloudWorkspace.parentRemoteURL(for: currentPath) {
                navigatePane(focusedPaneID, to: parent)
                selectedSidebarPath = parent
                activePanePath = parent
            }
            return
        }
        let parent = currentPath.deletingLastPathComponent()
        navigatePane(focusedPaneID, to: parent)
        selectedSidebarPath = parent
        activePanePath = parent
    }

    private func handleSetViewMode(_ notification: Notification) {
        guard let focusedPaneID,
              let modeValue = notification.object as? String,
              let newMode = mode(for: modeValue) else { return }

        if syncPaneViewModes {
            for paneID in paneStates.keys {
                paneStates[paneID]?.viewMode = newMode
            }
        } else {
            paneStates[focusedPaneID]?.viewMode = newMode
        }
        viewMode = newMode
    }

    private func handlePreviewSelectionChange(for paneID: UUID, item: FilePreviewItem?) {
        guard paneStates[paneID] != nil else { return }
        paneStates[paneID]?.previewItem = item
        if focusedPaneID == paneID {
            sharedPreviewItem = item
        }
    }

    private func handlePreviewRename(_ url: URL, _ newName: String) {
        if let newURL = fileOps.renameFile(at: url, to: newName) {
            // Update preview item with new name
            if let paneID = focusedPaneID, var preview = paneStates[paneID]?.previewItem {
                let info = fileOps.getFileInfo(url: newURL)
                let fileItem = FileItem.fromURL(newURL)
                if let fileItem {
                    paneStates[paneID]?.previewItem = FilePreviewItem(file: fileItem, info: info)
                }
            }
            NotificationCenter.default.post(name: .refreshFiles, object: nil)
        }
    }

    private func handlePreviewTagsChanged(_ url: URL, _ tags: [String]) {
        var resourceValues = URLResourceValues()
        resourceValues.tagNames = tags
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)

        // Update preview item with new tags
        if let paneID = focusedPaneID, var preview = paneStates[paneID]?.previewItem {
            let info = fileOps.getFileInfo(url: url)
            let fileItem = FileItem.fromURL(url)
            if let fileItem {
                paneStates[paneID]?.previewItem = FilePreviewItem(file: fileItem, info: info)
            }
        }
        NotificationCenter.default.post(name: .refreshFiles, object: nil)
    }

    private func handlePreviewRefresh() {
        NotificationCenter.default.post(name: .refreshFiles, object: nil)
    }

    private func selectTab(at index: Int, inOtherPane: Bool) {
        guard index >= 0 else { return }

        let targetPaneID: UUID?
        if inOtherPane {
            targetPaneID = otherPaneID()
        } else {
            targetPaneID = focusedPaneID
        }

        guard let paneID = targetPaneID,
              var pane = paneStates[paneID],
              index < pane.tabs.count else { return }

        pane.selectedTabId = pane.tabs[index].id
        pane.previewItem = nil
        paneStates[paneID] = pane

        if !inOtherPane {
            focusedPaneID = paneID
            syncFocusedPaneState()
        }
    }

    @discardableResult
    private func handleDroppedTab(_ payload: TabDragPayload, into targetPaneID: UUID, targetIndex: Int?) -> Bool {
        guard var sourcePane = paneStates[payload.sourcePaneID],
              var targetPane = paneStates[targetPaneID],
              let sourceIndex = sourcePane.tabs.firstIndex(where: { $0.id == payload.tabID }) else {
            return false
        }

        let movedTab = sourcePane.tabs[sourceIndex]

        if payload.sourcePaneID == targetPaneID {
            var tabs = sourcePane.tabs
            tabs.remove(at: sourceIndex)

            var insertionIndex = targetIndex ?? tabs.count
            insertionIndex = max(0, min(insertionIndex, tabs.count))
            if insertionIndex > sourceIndex {
                insertionIndex -= 1
            }

            tabs.insert(movedTab, at: insertionIndex)
            sourcePane.tabs = tabs
            sourcePane.selectedTabId = movedTab.id
            paneStates[targetPaneID] = sourcePane
            focusedPaneID = targetPaneID
            syncFocusedPaneState()
            return true
        }

        sourcePane.tabs.remove(at: sourceIndex)
        if sourcePane.tabs.isEmpty {
            paneStates.removeValue(forKey: payload.sourcePaneID)
            layoutTree = removingPane(from: layoutTree, paneID: payload.sourcePaneID) ?? layoutTree
        } else if sourcePane.selectedTabId == movedTab.id {
            sourcePane.selectedTabId = sourcePane.tabs.first?.id
            sourcePane.previewItem = nil
            paneStates[payload.sourcePaneID] = sourcePane
        }

        var insertionIndex = targetIndex ?? targetPane.tabs.count
        insertionIndex = max(0, min(insertionIndex, targetPane.tabs.count))
        targetPane.tabs.insert(movedTab, at: insertionIndex)
        targetPane.selectedTabId = movedTab.id
        targetPane.previewItem = nil

        paneStates[targetPaneID] = targetPane
        focusedPaneID = targetPaneID
        syncFocusedPaneState()
        return true
    }

    private func closeFocusedWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func otherPaneID() -> UUID? {
        let paneIDs = layoutTree.allPaneIDs()
        guard paneIDs.count > 1 else { return nil }
        guard let focusedPaneID else { return paneIDs.first }
        return paneIDs.first(where: { $0 != focusedPaneID })
    }

    private func syncFocusedPaneState() {
        guard let focusedPaneID,
              let pane = paneStates[focusedPaneID] else { return }
        activePanePath = pane.currentPath
        selectedSidebarPath = pane.currentPath
        viewMode = pane.viewMode
        sharedPreviewItem = pane.previewItem
    }

    private func postFocusedPaneCommand(_ name: Notification.Name) {
        guard focusedPaneID != nil else { return }
        NotificationCenter.default.post(
            name: name,
            object: focusedPaneID
        )
    }

    private func focusAdjacentPane() {
        let paneIDs = layoutTree.allPaneIDs()
        guard !paneIDs.isEmpty else { return }

        guard let focusedPaneID,
              let currentIndex = paneIDs.firstIndex(of: focusedPaneID) else {
            self.focusedPaneID = paneIDs.first
            syncFocusedPaneState()
            return
        }

        let nextIndex = (currentIndex + 1) % paneIDs.count
        self.focusedPaneID = paneIDs[nextIndex]
        syncFocusedPaneState()
    }

    private func addPane(nextTo paneID: UUID, axis: PaneAxis) {
        guard canAddPane(axis: axis) else { return }

        let basePath = paneStates[paneID]?.currentPath ?? (initialPath ?? FileManager.default.homeDirectoryForCurrentUser)
        let newPane = PaneState(path: basePath, viewMode: paneStates[paneID]?.viewMode ?? viewMode)
        paneStates[newPane.id] = newPane
        layoutTree = insertPane(into: layoutTree, targetPaneID: paneID, newPaneID: newPane.id, axis: axis, beforeTarget: false)
        focusedPaneID = newPane.id
        activePanePath = newPane.currentPath
        viewMode = newPane.viewMode
    }

    private func removePane(_ paneID: UUID) {
        guard paneStates.count > 1 else { return }

        paneStates.removeValue(forKey: paneID)
        layoutTree = removingPane(from: layoutTree, paneID: paneID) ?? layoutTree

        if focusedPaneID == paneID {
            focusedPaneID = layoutTree.allPaneIDs().first
        }

        syncFocusedPaneState()
    }

    private func rebuildWorkspace(for preset: WorkspaceLayoutPreset) {
        let paneIDs = Array(paneStates.keys)
        guard !paneIDs.isEmpty else { return }
        layoutTree = Self.defaultLayout(for: paneIDs, preset: preset)
        if focusedPaneID == nil {
            focusedPaneID = paneIDs.first
        }
    }

    private static func defaultLayout(for paneIDs: [UUID], preset: WorkspaceLayoutPreset) -> PaneNode {
        let nodes = paneIDs.map { PaneNode.pane($0) }

        switch preset {
        case .horizontal:
            if nodes.count == 1 { return nodes[0] }
            return .split(id: UUID(), axis: .horizontal, children: nodes)
        case .vertical:
            if nodes.count == 1 { return nodes[0] }
            return .split(id: UUID(), axis: .vertical, children: nodes)
        case .grid:
            if nodes.count == 1 { return nodes[0] }
            if nodes.count == 2 {
                return .split(id: UUID(), axis: .horizontal, children: Array(nodes))
            }
            let columnCount = max(1, Int(ceil(sqrt(Double(nodes.count)))))
            let rowCount = Int(ceil(Double(nodes.count) / Double(columnCount)))
            var rows: [PaneNode] = []
            for row in 0..<rowCount {
                let start = row * columnCount
                let end = min(start + columnCount, nodes.count)
                guard start < nodes.count else { break }
                let rowNodes = Array(nodes[start..<end])
                rows.append(rowNodes.count == 1 ? rowNodes[0] : .split(id: UUID(), axis: .horizontal, children: rowNodes))
            }
            return rows.count == 1 ? rows[0] : .split(id: UUID(), axis: .vertical, children: rows)
        }
    }

    private func filteredLayoutTree(_ node: PaneNode, validPaneIDs: Set<UUID>) -> PaneNode? {
        switch node {
        case .pane(let id):
            return validPaneIDs.contains(id) ? node : nil
        case .split(let id, let axis, let children):
            let filtered = children.compactMap { filteredLayoutTree($0, validPaneIDs: validPaneIDs) }
            if filtered.isEmpty { return nil }
            if filtered.count == 1 { return filtered[0] }
            return .split(id: id, axis: axis, children: filtered)
        }
    }

    private func mode(for rawValue: String) -> FileBrowserView.ViewMode? {
        switch rawValue {
        case "icon": return .icon
        case "list": return .list
        case "column": return .column
        default: return nil
        }
    }

    private func insertPane(
        into node: PaneNode,
        targetPaneID: UUID,
        newPaneID: UUID,
        axis: PaneAxis,
        beforeTarget: Bool
    ) -> PaneNode {
        switch node {
        case .pane(let id):
            guard id == targetPaneID else { return node }
            let ordered: [PaneNode] = beforeTarget
                ? [.pane(newPaneID), .pane(id)]
                : [.pane(id), .pane(newPaneID)]
            return .split(id: UUID(), axis: axis, children: ordered)

        case .split(let id, let currentAxis, let children):
            return .split(
                id: id,
                axis: currentAxis,
                children: children.map {
                    insertPane(
                        into: $0,
                        targetPaneID: targetPaneID,
                        newPaneID: newPaneID,
                        axis: axis,
                        beforeTarget: beforeTarget
                    )
                }
            )
        }
    }

    private func removingPane(from node: PaneNode, paneID: UUID) -> PaneNode? {
        switch node {
        case .pane(let id):
            return id == paneID ? nil : node

        case .split(let id, let axis, let children):
            let updatedChildren = children.compactMap { removingPane(from: $0, paneID: paneID) }

            if updatedChildren.isEmpty { return nil }
            if updatedChildren.count == 1 { return updatedChildren[0] }
            return .split(id: id, axis: axis, children: updatedChildren)
        }
    }

}

struct PaneWorkspaceNodeView: View {
    @Binding var node: PaneNode
    @Binding var paneStates: [UUID: PaneState]
    @Binding var focusedPaneID: UUID?
    @Binding var showHiddenFiles: Bool
    @Binding var selectedSidebarPath: URL?
    @Binding var activePanePath: URL

    var searchText: String
    var pathBarEnabled: Bool
    var statusBarEnabled: Bool
    var cloudWorkspace: CloudWorkspaceModel
    var canAddPane: Bool
    var canClosePane: Bool
    var showFocusRing: Bool
    var onViewModeChange: (UUID, FileBrowserView.ViewMode) -> Void
    var onAddSiblingPane: (UUID, PaneAxis) -> Void
    var onRemovePane: (UUID) -> Void
    var onPreviewSelectionChange: (UUID, FilePreviewItem?) -> Void
    var onDropTab: (TabDragPayload, UUID, Int?) -> Bool

    var body: some View {
        switch node {
        case .pane(let paneID):
            if let paneBinding = binding(for: paneID) {
                WorkspacePaneContainerView(
                    paneID: paneID,
                    paneState: paneBinding,
                    showHiddenFiles: $showHiddenFiles,
                    selectedSidebarPath: $selectedSidebarPath,
                    activePanePath: $activePanePath,
                    isFocused: focusedPaneID == paneID,
                    searchText: searchText,
                    pathBarEnabled: pathBarEnabled,
                    statusBarEnabled: statusBarEnabled,
                    cloudWorkspace: cloudWorkspace,
                    canAddPane: canAddPane,
                    canClosePane: canClosePane,
                    showFocusRing: showFocusRing,
                    onFocus: {
                        focusedPaneID = paneID
                        if let pane = paneStates[paneID] {
                            selectedSidebarPath = pane.currentPath
                            activePanePath = pane.currentPath
                            onViewModeChange(paneID, pane.viewMode)
                        }
                    },
                    onViewModeChange: { mode in
                        onViewModeChange(paneID, mode)
                    },
                    onAddHorizontal: {
                        onAddSiblingPane(paneID, .horizontal)
                    },
                    onAddVertical: {
                        onAddSiblingPane(paneID, .vertical)
                    },
                    onClosePane: {
                        onRemovePane(paneID)
                    },
                    onPreviewSelectionChange: { previewItem in
                        onPreviewSelectionChange(paneID, previewItem)
                    },
                    onDropTab: { payload, targetIndex in
                        onDropTab(payload, paneID, targetIndex)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

        case .split(_, let axis, let children):
            PaneSplitContainer(
                axis: axis,
                children: children.indices.map { index in
                    AnyView(
                        PaneWorkspaceNodeView(
                            node: childBinding(at: index),
                            paneStates: $paneStates,
                            focusedPaneID: $focusedPaneID,
                            showHiddenFiles: $showHiddenFiles,
                            selectedSidebarPath: $selectedSidebarPath,
                            activePanePath: $activePanePath,
                            searchText: searchText,
                            pathBarEnabled: pathBarEnabled,
                            statusBarEnabled: statusBarEnabled,
                            cloudWorkspace: cloudWorkspace,
                            canAddPane: canAddPane,
                            canClosePane: canClosePane,
                            showFocusRing: showFocusRing,
                            onViewModeChange: onViewModeChange,
                            onAddSiblingPane: onAddSiblingPane,
                            onRemovePane: onRemovePane,
                            onPreviewSelectionChange: onPreviewSelectionChange,
                            onDropTab: onDropTab
                        )
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity, alignment: .topLeading)
                    )
                }
            )
        }
    }

    private func childBinding(at index: Int) -> Binding<PaneNode> {
        Binding(
            get: {
                guard case .split(_, _, let children) = node else { return node }
                return children[index]
            },
            set: { newValue in
                guard case .split(let id, let axis, var children) = node else { return }
                children[index] = newValue
                node = .split(id: id, axis: axis, children: children)
            }
        )
    }

    private func binding(for paneID: UUID) -> Binding<PaneState>? {
        guard paneStates[paneID] != nil else { return nil }
        return Binding(
            get: { paneStates[paneID] ?? PaneState() },
            set: { paneStates[paneID] = $0 }
        )
    }
}

struct PaneSplitContainer: View {
    let axis: PaneAxis
    let children: [AnyView]
    @State private var ratios: [CGFloat]
    @State private var dragStartRatios: [CGFloat] = []

    init(axis: PaneAxis, children: [AnyView]) {
        self.axis = axis
        self.children = children
        let count = max(children.count, 1)
        self._ratios = State(initialValue: Array(repeating: 1.0 / CGFloat(count), count: count))
    }

    private var effectiveRatios: [CGFloat] {
        if ratios.count == children.count {
            return ratios
        }
        let count = max(children.count, 1)
        return Array(repeating: 1.0 / CGFloat(count), count: count)
    }

    var body: some View {
        GeometryReader { geometry in
            let currentRatios = effectiveRatios
            let totalSize = axis == .horizontal ? geometry.size.width : geometry.size.height
            let dividerCount = CGFloat(max(children.count - 1, 0))
            let dividerThickness: CGFloat = 6
            let availableSize = max(totalSize - dividerCount * dividerThickness, 1)

            if axis == .horizontal {
                HStack(spacing: 0) {
                    ForEach(Array(children.indices), id: \.self) { index in
                        children[index]
                            .frame(width: max(availableSize * currentRatios[index], 60))

                        if index < children.count - 1 {
                            PaneDividerView(
                                axis: axis,
                                onDragStart: { dragStartRatios = ratios },
                                onDrag: { delta in
                                    handleDrag(index: index, delta: delta, availableSize: availableSize)
                                },
                                onDoubleTap: { resetRatios() }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(children.indices), id: \.self) { index in
                        children[index]
                            .frame(height: max(availableSize * currentRatios[index], 60))

                        if index < children.count - 1 {
                            PaneDividerView(
                                axis: axis,
                                onDragStart: { dragStartRatios = ratios },
                                onDrag: { delta in
                                    handleDrag(index: index, delta: delta, availableSize: availableSize)
                                },
                                onDoubleTap: { resetRatios() }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: children.count) { _, newCount in
            let count = max(newCount, 1)
            ratios = Array(repeating: 1.0 / CGFloat(count), count: count)
        }
    }

    private func handleDrag(index: Int, delta: CGFloat, availableSize: CGFloat) {
        guard availableSize > 0, index < dragStartRatios.count - 1 else { return }
        let ratioDelta = delta / availableSize
        let minRatio: CGFloat = 0.10
        let combined = dragStartRatios[index] + dragStartRatios[index + 1]

        var newLeft = dragStartRatios[index] + ratioDelta
        var newRight = dragStartRatios[index + 1] - ratioDelta

        if newLeft < minRatio {
            newLeft = minRatio
            newRight = combined - minRatio
        }
        if newRight < minRatio {
            newRight = minRatio
            newLeft = combined - minRatio
        }

        ratios[index] = newLeft
        ratios[index + 1] = newRight
    }

    private func resetRatios() {
        let count = max(children.count, 1)
        ratios = Array(repeating: 1.0 / CGFloat(count), count: count)
    }
}

struct PaneDividerView: View {
    let axis: PaneAxis
    let onDragStart: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDoubleTap: () -> Void

    @State private var isHovering = false
    @State private var dragStartPosition: CGFloat?

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color(nsColor: .controlAccentColor).opacity(0.5) : Color(nsColor: .separatorColor))
            .frame(
                width: axis == .horizontal ? (isHovering ? 4 : 1) : nil,
                height: axis == .vertical ? (isHovering ? 4 : 1) : nil
            )
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .vertical ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    if axis == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let current = axis == .horizontal ? value.location.x : value.location.y
                        if dragStartPosition == nil {
                            dragStartPosition = current
                            onDragStart()
                        }
                        let delta = current - (dragStartPosition ?? current)
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        dragStartPosition = nil
                    }
            )
            .onTapGesture(count: 2) {
                onDoubleTap()
            }
    }
}

private struct PanePointerFocusObserver: NSViewRepresentable {
    var onPointerDown: () -> Void

    func makeNSView(context: Context) -> FocusObserverNSView {
        let view = FocusObserverNSView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: FocusObserverNSView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }

    static func dismantleNSView(_ nsView: FocusObserverNSView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class FocusObserverNSView: NSView {
        var onPointerDown: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startMonitoring()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stopMonitoring()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func startMonitoring() {
            stopMonitoring()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window else {
                    return event
                }

                let pointInView = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(pointInView) {
                    self.onPointerDown?()
                }

                return event
            }
        }

        func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            stopMonitoring()
        }
    }
}

struct WorkspacePaneContainerView: View {
    enum FileBrowserCommand: Equatable {
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

    let paneID: UUID
    @Binding var paneState: PaneState
    @Binding var showHiddenFiles: Bool
    @Binding var selectedSidebarPath: URL?
    @Binding var activePanePath: URL

    var isFocused: Bool
    var searchText: String
    var pathBarEnabled: Bool
    var statusBarEnabled: Bool
    var cloudWorkspace: CloudWorkspaceModel
    var canAddPane: Bool
    var canClosePane: Bool
    var showFocusRing: Bool
    var onFocus: () -> Void
    var onViewModeChange: (FileBrowserView.ViewMode) -> Void
    var onAddHorizontal: () -> Void
    var onAddVertical: () -> Void
    var onClosePane: () -> Void
    var onPreviewSelectionChange: (FilePreviewItem?) -> Void
    var onDropTab: (TabDragPayload, Int?) -> Bool
    @EnvironmentObject private var fileOps: FileOperations

    @State private var fileBrowserCommand: FileBrowserCommand?
    @State private var paneSearchText: String = ""
    @State private var paneSearchActive: Bool = false
    @State private var recursiveSearch: Bool = false
    @State private var recursiveResults: [FileItem] = []
    @State private var recursiveSearchTask: Task<Void, Never>?

    var body: some View {
        let baseView = paneContainer
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                PanePointerFocusObserver(onPointerDown: onFocus)
            )

        let commandView = baseView
            .onReceive(NotificationCenter.default.publisher(for: .duplicateSelectedFiles)) { notification in
                handlePaneCommandNotification(notification, command: .duplicate)
            }
            .onReceive(NotificationCenter.default.publisher(for: .copySelectedFiles)) { notification in
                handlePaneCommandNotification(notification, command: .copy)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cutSelectedFiles)) { notification in
                handlePaneCommandNotification(notification, command: .cut)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteFiles)) { notification in
                handlePaneCommandNotification(notification, command: .paste)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllFiles)) { notification in
                handlePaneCommandNotification(notification, command: .selectAll)
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickLookSelected)) { notification in
                handlePaneCommandNotification(notification, command: .quickLook)
            }
            .onReceive(NotificationCenter.default.publisher(for: .getInfoSelected)) { notification in
                handlePaneCommandNotification(notification, command: .getInfo)
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameSelected)) { notification in
                handlePaneCommandNotification(notification, command: .rename)
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshFiles)) { notification in
                handlePaneCommandNotification(notification, command: .refresh)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInTerminal)) { notification in
                handlePaneCommandNotification(notification, command: .openInTerminal)
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToFolder)) { notification in
                handlePaneCommandNotification(notification, command: .openPathPrompt)
            }

        return commandView
    }

    @ViewBuilder
    private var paneContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTabStripView(
                paneID: paneID,
                tabs: paneState.tabs,
                selectedTabID: paneState.selectedTabId,
                onSelect: { tab in
                    selectTab(tab)
                },
                onClose: { tab in
                    closeTab(tab)
                },
                onNewTab: {
                    addNewTab()
                },
                onDropTab: onDropTab,
                onDropFiles: handleDroppedFiles(_:onto:)
            )

            Divider()

            // Per-pane search bar
            if paneSearchActive {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search in pane…", text: $paneSearchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if recursiveSearch {
                                performRecursiveSearch()
                            }
                        }
                    Toggle("Recursive", isOn: $recursiveSearch)
                        .toggleStyle(.checkbox)
                        .help("Search in subdirectories")
                    Button {
                        paneSearchText = ""
                        paneSearchActive = false
                        recursiveResults = []
                        recursiveSearchTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }

            if let selectedTab = selectedTab {
                tabContent(for: selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            ensureValidSelection()
            updateSelectionStateForCurrentTab()
        }
        .onChange(of: paneState.selectedTabId) { _, _ in
            ensureValidSelection()
            updateSelectionStateForCurrentTab()
        }
        .onChange(of: paneState.tabs) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: paneSearchText) { _, _ in
            // Debounce recursive search
            if recursiveSearch && !paneSearchText.isEmpty {
                recursiveSearchTask?.cancel()
                recursiveSearchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { performRecursiveSearch() }
                }
            } else {
                recursiveResults = []
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(showFocusRing && isFocused ? Color(nsColor: .controlAccentColor).opacity(0.5) : Color.clear, lineWidth: 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let selectedTab, selectedTab.path.isFileURL else { return false }
            return handleDroppedFiles(urls, onto: selectedTab)
        }
    }

    private var selectedTab: FileTab? {
        if let id = paneState.selectedTabId,
           let match = paneState.tabs.first(where: { $0.id == id }) {
            return match
        }
        return paneState.tabs.first
    }

    @ViewBuilder
    private func tabContent(for tab: FileTab) -> some View {
        let effectiveSearch = paneSearchActive ? paneSearchText : searchText
        if isCloudTab(tab) {
            CloudPaneView(
                currentPath: pathBinding(for: tab.id),
                searchText: effectiveSearch,
                workspace: cloudWorkspace
            )
            .onAppear {
                if paneState.selectedTabId == tab.id {
                    onPreviewSelectionChange(nil)
                }
            }
        } else {
            FileBrowserView(
                currentPath: pathBinding(for: tab.id),
                viewMode: Binding(
                    get: { paneState.viewMode },
                    set: { newMode in
                        paneState.viewMode = newMode
                        onViewModeChange(newMode)
                    }
                ),
                showHiddenFiles: $showHiddenFiles,
                searchText: effectiveSearch,
                showsPathBar: pathBarEnabled,
                showsStatusBar: statusBarEnabled,
                externalCommand: paneState.selectedTabId == tab.id ? externalFileBrowserCommand : nil,
                onPreviewSelectionChange: { previewItem in
                    guard paneState.selectedTabId == tab.id else { return }
                    onPreviewSelectionChange(previewItem)
                },
                onInteraction: {
                    onFocus()
                }
            )
        }
    }

    private func pathBinding(for tabID: UUID) -> Binding<URL> {
        Binding(
            get: {
                paneState.tabs.first(where: { $0.id == tabID })?.path
                    ?? paneState.currentPath
            },
            set: { newPath in
                guard let index = paneState.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                paneState.tabs[index].path = newPath
                paneState.tabs[index].title = VirtualLocation.displayName(for: newPath)

                if paneState.selectedTabId == tabID {
                    selectedSidebarPath = newPath
                    activePanePath = newPath
                }
            }
        )
    }

    private func ensureValidSelection() {
        if paneState.selectedTabId == nil || !paneState.tabs.contains(where: { $0.id == paneState.selectedTabId }) {
            paneState.selectedTabId = paneState.tabs.first?.id
        }
    }

    private func addNewTab() {
        paneState.addTab(path: paneState.currentPath)
        onFocus()
        updateSelectionStateForCurrentTab()
    }

    private func closeTab(_ tab: FileTab) {
        if paneState.tabs.count == 1 {
            if canClosePane {
                onClosePane()
            } else {
                NSApp.keyWindow?.performClose(nil)
            }
            return
        }

        guard let index = paneState.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        paneState.tabs.remove(at: index)

        if paneState.selectedTabId == tab.id {
            paneState.selectedTabId = paneState.tabs[min(index, paneState.tabs.count - 1)].id
        }

        updateSelectionStateForCurrentTab()
    }

    private func selectTab(_ tab: FileTab) {
        guard paneState.selectedTabId != tab.id else { return }
        paneState.selectedTabId = tab.id
        onFocus()
        updateSelectionStateForCurrentTab()
    }

    private func isCloudTab(_ tab: FileTab) -> Bool {
        tab.path.scheme == "neutron-cloud" || tab.path.scheme == "neutron-s3"
    }

    private func updateSelectionStateForCurrentTab() {
        guard let selectedTabID = paneState.selectedTabId,
              let selectedTab = paneState.tabs.first(where: { $0.id == selectedTabID }) else {
            onPreviewSelectionChange(nil)
            return
        }

        selectedSidebarPath = selectedTab.path
        activePanePath = selectedTab.path
        onPreviewSelectionChange(nil)
    }

    private func isFocusedPaneNotification(_ notification: Notification) -> Bool {
        guard let targetPaneID = notification.object as? UUID else { return false }
        return targetPaneID == paneID
    }

    private var externalFileBrowserCommand: FileBrowserView.ExternalCommand? {
        guard let fileBrowserCommand else { return nil }
        switch fileBrowserCommand {
        case .duplicate: return .duplicate
        case .copy: return .copy
        case .cut: return .cut
        case .paste: return .paste
        case .selectAll: return .selectAll
        case .quickLook: return .quickLook
        case .getInfo: return .getInfo
        case .rename: return .rename
        case .refresh: return .refresh
        case .openInTerminal: return .openInTerminal
        case .openPathPrompt: return .openPathPrompt
        }
    }

    private func handlePaneCommandNotification(_ notification: Notification, command: FileBrowserCommand) {
        guard isFocusedPaneNotification(notification) else { return }
        if fileBrowserCommand == command {
            fileBrowserCommand = nil
            DispatchQueue.main.async {
                fileBrowserCommand = command
            }
        } else {
            fileBrowserCommand = command
        }
    }

    private func handleDroppedFiles(_ urls: [URL], onto tab: FileTab) -> Bool {
        guard tab.path.isFileURL else { return false }
        guard FileManager.default.fileExists(atPath: tab.path.path) else { return false }

        let destination = tab.path.standardizedFileURL
        var affectedDirectories = Set([destination.path])
        for url in urls where url.isFileURL {
            affectedDirectories.insert(url.standardizedFileURL.deletingLastPathComponent().path)
        }

        guard fileOps.moveFiles(urls: urls, to: destination) else { return false }

        NotificationCenter.default.post(
            name: .fileSystemEntriesMoved,
            object: nil,
            userInfo: ["affectedDirectories": Array(affectedDirectories)]
        )

        paneState.selectedTabId = tab.id
        onFocus()
        updateSelectionStateForCurrentTab()
        return true
    }

    private func performRecursiveSearch() {
        let query = paneSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            recursiveResults = []
            return
        }

        let root = paneState.currentPath
        Task.detached(priority: .userInitiated) {
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .tagNamesKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            var found: [FileItem] = []
            var count = 0

            while let url = enumerator?.nextObject() as? URL {
                count += 1
                if count > 10000 { break }

                if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    if let item = FileItem.fromURL(url) {
                        found.append(item)
                    }
                }
            }

            let results = found
            await MainActor.run {
                self.recursiveResults = results
            }
        }
    }
}

private struct PaneTabStripView: View {
    let paneID: UUID
    let tabs: [FileTab]
    let selectedTabID: UUID?
    var onSelect: (FileTab) -> Void
    var onClose: (FileTab) -> Void
    var onNewTab: () -> Void
    var onDropTab: (TabDragPayload, Int?) -> Bool
    var onDropFiles: ([URL], FileTab) -> Bool

    @State private var dropIndex: Int?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        let payload = TabDragPayload(
                            tabID: tab.id,
                            sourcePaneID: paneID,
                            title: tab.title,
                            path: tab.path.path
                        )

                        PaneTabStripItem(
                            title: tab.title,
                            isSelected: tab.id == selectedTabID,
                            isDropTargeted: dropIndex == index,
                            onSelect: {
                                onSelect(tab)
                            },
                            onClose: {
                                onClose(tab)
                            },
                            onDropFiles: { urls in
                                onDropFiles(urls, tab)
                            }
                        )
                        .draggable(payload.encoded() ?? "") {
                            TabDragPreview(title: tab.title)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first,
                                  let decoded = TabDragPayload.decode(raw) else { return false }
                            return onDropTab(decoded, index)
                        } isTargeted: { targeting in
                            dropIndex = targeting ? index : nil
                        }
                    }
                }
                .padding(.horizontal, 6)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first,
                          let decoded = TabDragPayload.decode(raw) else { return false }
                    return onDropTab(decoded, nil)
                } isTargeted: { targeting in
                    if !targeting {
                        dropIndex = nil
                    }
                }
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("New Tab")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabDragPreview: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .controlAccentColor).opacity(0.7), lineWidth: 1)
        }
    }
}

private struct PaneTabStripItem: View {
    let title: String
    let isSelected: Bool
    var isDropTargeted: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void
    var onDropFiles: ([URL]) -> Bool = { _ in false }

    @State private var isFileDropTargeted = false

    private var tabFill: Color {
        if isSelected {
            return Color(nsColor: .controlBackgroundColor)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tabFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.7)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .controlAccentColor), style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
        }
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .controlAccentColor), lineWidth: 1.2)
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .dropDestination(for: URL.self) { urls, _ in
            onDropFiles(urls)
        } isTargeted: { targeting in
            isFileDropTargeted = targeting
        }
    }
}

struct CloudPaneView: View {
    @Binding var currentPath: URL
    var searchText: String
    let workspace: CloudWorkspaceModel

    var body: some View {
        RemoteCloudBrowserView(
            currentPath: $currentPath,
            searchText: searchText,
            workspace: workspace
        )
    }
}

#Preview {
    DualPaneView(
        viewMode: .constant(.list),
        showHiddenFiles: .constant(false)
    )
}
