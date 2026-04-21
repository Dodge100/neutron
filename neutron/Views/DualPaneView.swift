import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

private let maxHorizontalPanes = 3
private let maxVerticalPanes = 2

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

    mutating func closeSelectedTab() {
        guard let selectedTabId,
              let index = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }

        tabs.remove(at: index)

        if tabs.isEmpty {
            addTab()
        } else {
            self.selectedTabId = tabs[min(index, tabs.count - 1)].id
        }
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
        guard let focusedPaneID else { return false }
        let maxForAxis = axis == .horizontal ? maxHorizontalPanes : maxVerticalPanes
        if let count = layoutTree.siblingCount(for: focusedPaneID, axis: axis) {
            return count < maxForAxis
        }
        return true
    }

    private var pathBarEnabled: Bool {
        UserDefaults.standard.object(forKey: "showPathBarInPanes") as? Bool ?? true
    }

    private var statusBarEnabled: Bool {
        UserDefaults.standard.object(forKey: "showStatusBarInPanes") as? Bool ?? true
    }

    var body: some View {
        let baseView = workspaceView
            .toolbar {
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

        let commandView = tabView
            .onReceive(NotificationCenter.default.publisher(for: .duplicateSelectedFiles)) { _ in
                postFocusedPaneCommand(.duplicateSelectedFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .copySelectedFiles)) { _ in
                postFocusedPaneCommand(.copySelectedFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cutSelectedFiles)) { _ in
                postFocusedPaneCommand(.cutSelectedFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteFiles)) { _ in
                postFocusedPaneCommand(.pasteFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllFiles)) { _ in
                postFocusedPaneCommand(.selectAllFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickLookSelected)) { _ in
                postFocusedPaneCommand(.quickLookSelected)
            }
            .onReceive(NotificationCenter.default.publisher(for: .getInfoSelected)) { _ in
                postFocusedPaneCommand(.getInfoSelected)
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameSelected)) { _ in
                postFocusedPaneCommand(.renameSelected)
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshFiles)) { _ in
                postFocusedPaneCommand(.refreshFiles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInTerminal)) { _ in
                postFocusedPaneCommand(.openInTerminal)
            }

        return commandView
            .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
                NotificationCenter.default.post(name: .toggleSearch, object: nil)
            }
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
            let previewRequested = sharedPreviewItem != nil
            let availablePreviewMax = max(0, totalWidth - minMainWidth)
            let effectivePreviewWidth = min(
                max(CGFloat(previewColumnWidth), minPreviewWidth),
                min(maxPreviewWidth, availablePreviewMax)
            )
            let canShowPreview = previewRequested && availablePreviewMax >= minPreviewWidth

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
                    onViewModeChange: handleViewModeChange,
                    onAddSiblingPane: addPane(nextTo:axis:),
                    onRemovePane: removePane(_:),
                    onPreviewSelectionChange: handlePreviewSelectionChange(for:item:),
                    onDropTab: handleDroppedTab(_:into:targetIndex:)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if canShowPreview, let sharedPreviewItem {
                    Divider()
                    FinderPreviewColumn(file: sharedPreviewItem)
                        .frame(width: effectivePreviewWidth)
                        .onAppear {
                            previewColumnWidth = Double(effectivePreviewWidth)
                        }
                }
            }
            .animation(.easeInOut(duration: 0.16), value: canShowPreview)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
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
        paneStates[focusedPaneID]?.closeSelectedTab()
        paneStates[focusedPaneID]?.previewItem = nil
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
            sourcePane.addTab(path: FileManager.default.homeDirectoryForCurrentUser)
        }
        if sourcePane.selectedTabId == movedTab.id {
            sourcePane.selectedTabId = sourcePane.tabs.first?.id
        }
        sourcePane.previewItem = nil

        var insertionIndex = targetIndex ?? targetPane.tabs.count
        insertionIndex = max(0, min(insertionIndex, targetPane.tabs.count))
        targetPane.tabs.insert(movedTab, at: insertionIndex)
        targetPane.selectedTabId = movedTab.id
        targetPane.previewItem = nil

        paneStates[payload.sourcePaneID] = sourcePane
        paneStates[targetPaneID] = targetPane
        focusedPaneID = targetPaneID
        syncFocusedPaneState()
        return true
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
        let maxTotal = maxHorizontalPanes * maxVerticalPanes
        let ids = paneIDs.prefix(maxTotal)
        let nodes = ids.map { PaneNode.pane($0) }

        switch preset {
        case .horizontal:
            if nodes.count == 1 { return nodes[0] }
            return .split(id: UUID(), axis: .horizontal, children: Array(nodes.prefix(maxHorizontalPanes)))
        case .vertical:
            if nodes.count == 1 { return nodes[0] }
            return .split(id: UUID(), axis: .vertical, children: Array(nodes.prefix(maxVerticalPanes)))
        case .grid:
            if nodes.count == 1 { return nodes[0] }
            if nodes.count == 2 {
                return .split(id: UUID(), axis: .horizontal, children: Array(nodes))
            }
            let rowCount = min(Int(ceil(Double(nodes.count) / Double(maxHorizontalPanes))), maxVerticalPanes)
            var rows: [PaneNode] = []
            for row in 0..<rowCount {
                let start = row * maxHorizontalPanes
                let end = min(start + maxHorizontalPanes, nodes.count)
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
            if currentAxis == axis,
               let targetIndex = children.firstIndex(where: { $0.containsPane(targetPaneID) }) {
                var newChildren = children
                let insertIndex = beforeTarget ? targetIndex : targetIndex + 1
                newChildren.insert(.pane(newPaneID), at: insertIndex)
                return .split(id: id, axis: currentAxis, children: newChildren)
            }

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
                            onViewModeChange: onViewModeChange,
                            onAddSiblingPane: onAddSiblingPane,
                            onRemovePane: onRemovePane,
                            onPreviewSelectionChange: onPreviewSelectionChange,
                            onDropTab: onDropTab
                        )
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
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
            let availableSize = totalSize - dividerCount * dividerThickness

            if axis == .horizontal {
                HStack(spacing: 0) {
                    ForEach(Array(children.indices), id: \.self) { index in
                        children[index]
                            .frame(width: availableSize * currentRatios[index])

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
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(children.indices), id: \.self) { index in
                        children[index]
                            .frame(height: availableSize * currentRatios[index])

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
            }
        }
        .onChange(of: children.count) { _, _ in
            resetRatios()
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
    var onFocus: () -> Void
    var onViewModeChange: (FileBrowserView.ViewMode) -> Void
    var onAddHorizontal: () -> Void
    var onAddVertical: () -> Void
    var onClosePane: () -> Void
    var onPreviewSelectionChange: (FilePreviewItem?) -> Void
    var onDropTab: (TabDragPayload, Int?) -> Bool

    @State private var fileBrowserCommand: FileBrowserCommand?

    var body: some View {
        let baseView = paneContainer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    onFocus()
                }
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

        return commandView
    }

    @ViewBuilder
    private var paneContainer: some View {
        VStack(spacing: 0) {
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
                onDropTab: onDropTab
            )

            Divider()

            if let selectedTab = selectedTab {
                tabContent(for: selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(isFocused ? Color(nsColor: .controlAccentColor).opacity(0.5) : Color.clear, lineWidth: 1)
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
        if isCloudTab(tab) {
            CloudPaneView(
                currentPath: pathBinding(for: tab.id),
                searchText: searchText,
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
                searchText: searchText,
                showsPathBar: pathBarEnabled,
                showsStatusBar: statusBarEnabled,
                externalCommand: paneState.selectedTabId == tab.id ? externalFileBrowserCommand : nil,
                onPreviewSelectionChange: { previewItem in
                    guard paneState.selectedTabId == tab.id else { return }
                    onPreviewSelectionChange(previewItem)
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
        guard let index = paneState.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        paneState.tabs.remove(at: index)

        if paneState.tabs.isEmpty {
            paneState.addTab(path: paneState.currentPath)
        } else if paneState.selectedTabId == tab.id {
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
}

private struct PaneTabStripView: View {
    let paneID: UUID
    let tabs: [FileTab]
    let selectedTabID: UUID?
    var onSelect: (FileTab) -> Void
    var onClose: (FileTab) -> Void
    var onNewTab: () -> Void
    var onDropTab: (TabDragPayload, Int?) -> Bool

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
                            alternate: index.isMultiple(of: 2),
                            isDropTargeted: dropIndex == index,
                            onSelect: {
                                onSelect(tab)
                            },
                            onClose: {
                                onClose(tab)
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
    let alternate: Bool
    var isDropTargeted: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var hovering = false

    private var tabFill: Color {
        if isSelected {
            return Color(nsColor: .controlBackgroundColor)
        }
        return alternate
            ? Color(nsColor: .underPageBackgroundColor).opacity(0.95)
            : Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)

            if hovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
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
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            self.hovering = hovering
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
