//
//  KeyboardShortcuts.swift
//  neutron
//
//  Hotkey customization system
//

import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox

// MARK: - Shortcut Action

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case newTab = "New Tab"
    case closeTab = "Close Tab"
    case splitPaneHorizontal = "Split Pane Horizontally"
    case splitPaneVertical = "Split Pane Vertically"
    case newFolder = "New Folder"
    case duplicate = "Duplicate"
    case delete = "Move to Trash"
    case copy = "Copy"
    case paste = "Paste"
    case cut = "Cut"
    case selectAll = "Select All"
    case search = "Search"
    case goBack = "Go Back"
    case goForward = "Go Forward"
    case goUp = "Go to Parent"
    case goHome = "Go to Home"
    case goDesktop = "Go to Desktop"
    case goDownloads = "Go to Downloads"
    case goDocuments = "Go to Documents"
    case goToFolder = "Open Path…"
    case toggleHidden = "Toggle Hidden Files"
    case quickLook = "Quick Look"
    case getInfo = "Get Info"
    case rename = "Rename"
    case openTerminal = "Open in Terminal"
    case refresh = "Refresh"
    case toggleRightPane = "Toggle Right Pane"
    case viewAsIcons = "View as Icons"
    case viewAsList = "View as List"
    case viewAsColumns = "View as Columns"
    case commandPalette = "Command Palette"
    
    var id: String { rawValue }
    
    var defaultShortcut: NeutronShortcut? {
        switch self {
        case .newTab: return NeutronShortcut(key: "t", modifiers: .command)
        case .closeTab: return NeutronShortcut(key: "w", modifiers: .command)
        case .splitPaneHorizontal: return NeutronShortcut(key: "d", modifiers: .command)
        case .splitPaneVertical: return NeutronShortcut(key: "d", modifiers: [.command, .shift])
        case .newFolder: return NeutronShortcut(key: "n", modifiers: [.command, .shift])
        case .duplicate: return NeutronShortcut(key: "d", modifiers: [.command, .option])
        case .delete: return NeutronShortcut(key: .delete, modifiers: .command)
        case .copy: return NeutronShortcut(key: "c", modifiers: .command)
        case .paste: return NeutronShortcut(key: "v", modifiers: .command)
        case .cut: return NeutronShortcut(key: "x", modifiers: .command)
        case .selectAll: return NeutronShortcut(key: "a", modifiers: .command)
        case .search: return NeutronShortcut(key: "f", modifiers: .command)
        case .goBack: return NeutronShortcut(key: "[", modifiers: .command)
        case .goForward: return NeutronShortcut(key: "]", modifiers: .command)
        case .goUp: return NeutronShortcut(key: .upArrow, modifiers: .command)
        case .goHome: return NeutronShortcut(key: "h", modifiers: [.command, .shift])
        case .goDesktop: return NeutronShortcut(key: "k", modifiers: [.command, .shift])
        case .goDownloads: return NeutronShortcut(key: "l", modifiers: [.command, .option])
        case .goDocuments: return NeutronShortcut(key: "o", modifiers: [.command, .shift])
        case .goToFolder: return NeutronShortcut(key: "g", modifiers: [.command, .shift])
        case .toggleHidden: return NeutronShortcut(key: ".", modifiers: [.command, .shift])
        case .quickLook: return NeutronShortcut(key: " ", modifiers: [])
        case .getInfo: return NeutronShortcut(key: "i", modifiers: .command)
        case .rename: return NeutronShortcut(key: .return, modifiers: [])
        case .openTerminal: return NeutronShortcut(key: "`", modifiers: .command)
        case .refresh: return NeutronShortcut(key: "r", modifiers: .command)
        case .toggleRightPane: return NeutronShortcut(key: "0", modifiers: .command)
        case .viewAsIcons: return NeutronShortcut(key: "1", modifiers: .command)
        case .viewAsList: return NeutronShortcut(key: "2", modifiers: .command)
        case .viewAsColumns: return NeutronShortcut(key: "3", modifiers: .command)
        case .commandPalette: return NeutronShortcut(key: "p", modifiers: [.command, .shift])
        }
    }
    
    var notificationName: Notification.Name {
        switch self {
        case .newTab: return .newTab
        case .closeTab: return .closeTab
        case .splitPaneHorizontal: return .splitPaneHorizontal
        case .splitPaneVertical: return .splitPaneVertical
        case .newFolder: return .createNewFolder
        case .duplicate: return .duplicateSelectedFiles
        case .delete: return .trashSelectedFiles
        case .copy: return .copySelectedFiles
        case .paste: return .pasteFiles
        case .cut: return .cutSelectedFiles
        case .selectAll: return .selectAllFiles
        case .search: return .toggleSearch
        case .goBack: return .navigateBack
        case .goForward: return .navigateForward
        case .goUp: return .goToParentFolder
        case .goHome: return .goHome
        case .goDesktop: return .goDesktop
        case .goDownloads: return .goDownloads
        case .goDocuments: return .goDocuments
        case .goToFolder: return .goToFolder
        case .toggleHidden: return .toggleHiddenFiles
        case .quickLook: return .quickLookSelected
        case .getInfo: return .getInfoSelected
        case .rename: return .renameSelected
        case .openTerminal: return .openInTerminal
        case .refresh: return .refreshFiles
        case .toggleRightPane: return .toggleRightPane
        case .viewAsIcons, .viewAsList, .viewAsColumns: return .setViewMode
        case .commandPalette: return .showCommandPalette
        }
    }

    func trigger() {
        switch self {
        case .viewAsIcons:
            NotificationCenter.default.post(name: .setViewMode, object: "icon")
        case .viewAsList:
            NotificationCenter.default.post(name: .setViewMode, object: "list")
        case .viewAsColumns:
            NotificationCenter.default.post(name: .setViewMode, object: "column")
        default:
            NotificationCenter.default.post(name: notificationName, object: nil)
        }
    }
}

// MARK: - Keyboard Shortcut Model

struct NeutronShortcut: Codable, Equatable {
    var key: KeyEquivalent
    var modifiers: SwiftUI.EventModifiers
    
    init(key: KeyEquivalent, modifiers: SwiftUI.EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }

        var modifiers: SwiftUI.EventModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let keyCode = Int(event.keyCode)

        switch keyCode {
        case kVK_Delete:
            self.init(key: .delete, modifiers: modifiers)
        case kVK_Return:
            self.init(key: .return, modifiers: modifiers)
        case kVK_Escape:
            self.init(key: .escape, modifiers: modifiers)
        case kVK_Tab:
            self.init(key: .tab, modifiers: modifiers)
        case kVK_Space:
            self.init(key: .space, modifiers: modifiers)
        case kVK_UpArrow:
            self.init(key: .upArrow, modifiers: modifiers)
        case kVK_DownArrow:
            self.init(key: .downArrow, modifiers: modifiers)
        case kVK_LeftArrow:
            self.init(key: .leftArrow, modifiers: modifiers)
        case kVK_RightArrow:
            self.init(key: .rightArrow, modifiers: modifiers)
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  let first = characters.first,
                  !characters.isEmpty else {
                return nil
            }
            self.init(key: KeyEquivalent(first), modifiers: modifiers)
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case keyCharacter, keyCode, modifierRaw
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyChar = try container.decodeIfPresent(String.self, forKey: .keyCharacter)
        let keyCode = try container.decodeIfPresent(Int.self, forKey: .keyCode)
        let modRaw = try container.decode(Int.self, forKey: .modifierRaw)
        
        if let char = keyChar, let first = char.first {
            self.key = KeyEquivalent(first)
        } else if let code = keyCode {
            switch code {
            case kVK_Delete: self.key = .delete
            case kVK_Return: self.key = .return
            case kVK_Escape: self.key = .escape
            case kVK_Tab: self.key = .tab
            case kVK_Space: self.key = .space
            case kVK_UpArrow: self.key = .upArrow
            case kVK_DownArrow: self.key = .downArrow
            case kVK_LeftArrow: self.key = .leftArrow
            case kVK_RightArrow: self.key = .rightArrow
            default: self.key = KeyEquivalent(" ")
            }
        } else {
            self.key = KeyEquivalent(" ")
        }
        
        self.modifiers = SwiftUI.EventModifiers(rawValue: modRaw)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Store the key as either a character or virtual key code
        let keyString = String(key.character)
        if keyString.count == 1 && !keyString.isEmpty {
            try container.encode(keyString, forKey: .keyCharacter)
        } else {
            // Map special keys to their virtual key codes
            let code: Int
            switch key {
            case .delete: code = kVK_Delete
            case .return: code = kVK_Return
            case .escape: code = kVK_Escape
            case .tab: code = kVK_Tab
            case .space: code = kVK_Space
            case .upArrow: code = kVK_UpArrow
            case .downArrow: code = kVK_DownArrow
            case .leftArrow: code = kVK_LeftArrow
            case .rightArrow: code = kVK_RightArrow
            default: code = 0
            }
            try container.encode(code, forKey: .keyCode)
        }
        
        try container.encode(modifiers.rawValue, forKey: .modifierRaw)
    }
    
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        
        let keyStr: String
        switch key {
        case .delete: keyStr = "⌫"
        case .return: keyStr = "↩"
        case .escape: keyStr = "⎋"
        case .tab: keyStr = "⇥"
        case .space: keyStr = "Space"
        case .upArrow: keyStr = "↑"
        case .downArrow: keyStr = "↓"
        case .leftArrow: keyStr = "←"
        case .rightArrow: keyStr = "→"
        default: keyStr = String(key.character).uppercased()
        }
        parts.append(keyStr)
        return parts.joined()
    }
}

// MARK: - Shortcut Manager

class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    
    @Published var shortcuts: [ShortcutAction: NeutronShortcut] = [:]
    
    private let userDefaultsKey = "customKeyboardShortcuts"
    private var eventMonitor: Any?

    /// Actions handled by global event monitor (not SwiftUI menu commands)
    private let monitoredActions: Set<ShortcutAction> = Set(ShortcutAction.allCases)

    init() {
        loadShortcuts()
        installGlobalMonitor()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Install local event monitor that intercepts key events and triggers matching actions.
    /// This makes custom shortcuts work dynamically without restarting.
    private func installGlobalMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let pressed = NeutronShortcut(event: event) else { return event }

            for action in ShortcutAction.allCases {
                guard let bound = self.shortcut(for: action) else { continue }
                if bound == pressed {
                    // Only intercept if user has a custom binding OR if this is a non-menu shortcut
                    if self.shortcuts[action] != nil || !self.hasMenuCommand(for: action) {
                        action.trigger()
                        return nil // consume event
                    }
                }
            }
            return event
        }
    }

    /// Whether action has a built-in SwiftUI menu command (avoid double-firing for defaults)
    private func hasMenuCommand(for action: ShortcutAction) -> Bool {
        switch action {
        case .newTab, .closeTab, .newFolder, .duplicate, .selectAll,
             .toggleHidden, .splitPaneHorizontal, .splitPaneVertical,
             .viewAsIcons, .viewAsList, .viewAsColumns,
             .goBack, .goForward, .goUp, .goHome, .goDesktop, .goDownloads, .goDocuments, .goToFolder,
             .openTerminal, .copy, .paste, .cut, .delete:
            return true
        case .search, .quickLook, .getInfo, .rename, .refresh, .toggleRightPane, .commandPalette:
            return false
        }
    }
    
    func shortcut(for action: ShortcutAction) -> NeutronShortcut? {
        shortcuts[action] ?? action.defaultShortcut
    }
    
    func setShortcut(_ shortcut: NeutronShortcut?, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        saveShortcuts()
    }
    
    func resetToDefault(action: ShortcutAction) {
        shortcuts.removeValue(forKey: action)
        saveShortcuts()
    }
    
    func resetAllToDefaults() {
        shortcuts.removeAll()
        saveShortcuts()
    }
    
    private func loadShortcuts() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([ShortcutAction: NeutronShortcut].self, from: data) else {
            return
        }
        shortcuts = decoded
    }
    
    private func saveShortcuts() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

extension View {
    @ViewBuilder
    func applyingShortcut(_ shortcut: NeutronShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let duplicateSelectedFiles = Notification.Name("neutron.duplicateSelectedFiles")
    static let copySelectedFiles = Notification.Name("neutron.copySelectedFiles")
    static let pasteFiles = Notification.Name("neutron.pasteFiles")
    static let cutSelectedFiles = Notification.Name("neutron.cutSelectedFiles")
    static let selectAllFiles = Notification.Name("neutron.selectAllFiles")
    static let toggleSearch = Notification.Name("neutron.toggleSearch")
    static let quickLookSelected = Notification.Name("neutron.quickLookSelected")
    static let getInfoSelected = Notification.Name("neutron.getInfoSelected")
    static let renameSelected = Notification.Name("neutron.renameSelected")
    static let openInTerminal = Notification.Name("neutron.openInTerminal")
    static let refreshFiles = Notification.Name("neutron.refreshFiles")
    static let toggleRightPane = Notification.Name("neutron.toggleRightPane")
    static let trashSelectedFiles = Notification.Name("neutron.trashSelectedFiles")
    static let shareSelectedFiles = Notification.Name("neutron.shareSelectedFiles")
    static let showCommandPalette = Notification.Name("neutron.showCommandPalette")
    static let fileSystemEntriesMoved = Notification.Name("neutron.fileSystemEntriesMoved")
}

// MARK: - Shortcut Recorder View

struct ShortcutRecorderView: View {
    let action: ShortcutAction
    @ObservedObject var manager = ShortcutManager.shared
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    
    var currentShortcut: NeutronShortcut? {
        manager.shortcut(for: action)
    }
    
    var body: some View {
        HStack {
            Text(action.rawValue)
                .frame(width: 150, alignment: .leading)
            
            Spacer()
            
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                if isRecording {
                    Text("Recording…")
                        .foregroundColor(.accentColor)
                        .frame(minWidth: 100)
                } else if let shortcut = currentShortcut {
                    Text(shortcut.displayString)
                        .frame(minWidth: 100)
                } else {
                    Text("None")
                        .foregroundColor(.secondary)
                        .frame(minWidth: 100)
                }
            }
            .buttonStyle(.bordered)
            .onDisappear(perform: stopRecording)
            
            Button {
                manager.resetToDefault(action: action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
        .padding(.vertical, 2)
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
                return nil
            }

            guard let shortcut = NeutronShortcut(event: event) else {
                return nil
            }

            manager.setShortcut(shortcut, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRecording = false
    }
}

// MARK: - Keyboard Shortcuts Settings View

struct KeyboardShortcutsSettingsView: View {
    @StateObject private var manager = ShortcutManager.shared
    @State private var searchText = ""
    
    var filteredActions: [ShortcutAction] {
        if searchText.isEmpty {
            return ShortcutAction.allCases
        }
        return ShortcutAction.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search shortcuts...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                
                Button("Reset All") {
                    manager.resetAllToDefaults()
                }
            }
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedActions.keys.sorted(), id: \.self) { category in
                        Section {
                            ForEach(groupedActions[category] ?? []) { action in
                                ShortcutRecorderView(action: action)
                            }
                        } header: {
                            Text(category)
                                .font(.headline)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
    
    var groupedActions: [String: [ShortcutAction]] {
        var groups: [String: [ShortcutAction]] = [:]
        
        let navigation: [ShortcutAction] = [.goBack, .goForward, .goUp, .goHome, .goDesktop, .goDownloads, .goDocuments, .goToFolder]
        let fileOps: [ShortcutAction] = [.newFolder, .duplicate, .delete, .copy, .paste, .cut, .rename]
        let view: [ShortcutAction] = [.viewAsIcons, .viewAsList, .viewAsColumns, .toggleHidden, .toggleRightPane, .refresh]
        let panes: [ShortcutAction] = [.splitPaneHorizontal, .splitPaneVertical]
        let tabs: [ShortcutAction] = [.newTab, .closeTab]
        let other: [ShortcutAction] = [.search, .selectAll, .quickLook, .getInfo, .openTerminal, .commandPalette]
        
        groups["Navigation"] = navigation.filter { filteredActions.contains($0) }
        groups["File Operations"] = fileOps.filter { filteredActions.contains($0) }
        groups["View"] = view.filter { filteredActions.contains($0) }
        groups["Panes"] = panes.filter { filteredActions.contains($0) }
        groups["Tabs"] = tabs.filter { filteredActions.contains($0) }
        groups["Other"] = other.filter { filteredActions.contains($0) }
        
        return groups.filter { !$0.value.isEmpty }
    }
}
