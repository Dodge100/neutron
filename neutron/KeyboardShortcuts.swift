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
    
    var id: String { rawValue }
    
    var defaultShortcut: NeutronShortcut? {
        switch self {
        case .newTab: return NeutronShortcut(key: "t", modifiers: .command)
        case .closeTab: return NeutronShortcut(key: "w", modifiers: .command)
        case .newFolder: return NeutronShortcut(key: "n", modifiers: [.command, .shift])
        case .duplicate: return NeutronShortcut(key: "d", modifiers: .command)
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
        case .goDesktop: return NeutronShortcut(key: "d", modifiers: [.command, .shift])
        case .goDownloads: return NeutronShortcut(key: "l", modifiers: [.command, .option])
        case .goDocuments: return NeutronShortcut(key: "o", modifiers: [.command, .shift])
        case .toggleHidden: return NeutronShortcut(key: ".", modifiers: [.command, .shift])
        case .quickLook: return NeutronShortcut(key: " ", modifiers: [])
        case .getInfo: return NeutronShortcut(key: "i", modifiers: .command)
        case .rename: return NeutronShortcut(key: .return, modifiers: [])
        case .openTerminal: return NeutronShortcut(key: "`", modifiers: .command)
        case .refresh: return NeutronShortcut(key: "r", modifiers: .command)
        case .toggleRightPane: return NeutronShortcut(key: "2", modifiers: .command)
        case .viewAsIcons: return NeutronShortcut(key: "1", modifiers: .command)
        case .viewAsList: return NeutronShortcut(key: "2", modifiers: [.command, .option])
        case .viewAsColumns: return NeutronShortcut(key: "3", modifiers: .command)
        }
    }
    
    var notificationName: Notification.Name {
        switch self {
        case .newTab: return .newTab
        case .closeTab: return .closeTab
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
        case .toggleHidden: return .toggleHiddenFiles
        case .quickLook: return .quickLookSelected
        case .getInfo: return .getInfoSelected
        case .rename: return .renameSelected
        case .openTerminal: return .openInTerminal
        case .refresh: return .refreshFiles
        case .toggleRightPane: return .toggleRightPane
        case .viewAsIcons: return Notification.Name("neutron.setViewModeIcon")
        case .viewAsList: return Notification.Name("neutron.setViewModeList")
        case .viewAsColumns: return Notification.Name("neutron.setViewModeColumn")
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
    
    init() {
        loadShortcuts()
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
}

// MARK: - Shortcut Recorder View

struct ShortcutRecorderView: View {
    let action: ShortcutAction
    @ObservedObject var manager = ShortcutManager.shared
    @State private var isRecording = false
    
    var currentShortcut: NeutronShortcut? {
        manager.shortcut(for: action)
    }
    
    var body: some View {
        HStack {
            Text(action.rawValue)
                .frame(width: 150, alignment: .leading)
            
            Spacer()
            
            Button {
                isRecording.toggle()
            } label: {
                if isRecording {
                    Text("Press keys...")
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
            .onKeyPress { keyPress in
                guard isRecording else { return .ignored }
                
                let newShortcut = NeutronShortcut(
                    key: keyPress.key,
                    modifiers: keyPress.modifiers
                )
                manager.setShortcut(newShortcut, for: action)
                isRecording = false
                return .handled
            }
            
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
        
        let navigation: [ShortcutAction] = [.goBack, .goForward, .goUp, .goHome, .goDesktop, .goDownloads, .goDocuments]
        let fileOps: [ShortcutAction] = [.newFolder, .duplicate, .delete, .copy, .paste, .cut, .rename]
        let view: [ShortcutAction] = [.viewAsIcons, .viewAsList, .viewAsColumns, .toggleHidden, .toggleRightPane, .refresh]
        let tabs: [ShortcutAction] = [.newTab, .closeTab]
        let other: [ShortcutAction] = [.search, .selectAll, .quickLook, .getInfo, .openTerminal]
        
        groups["Navigation"] = navigation.filter { filteredActions.contains($0) }
        groups["File Operations"] = fileOps.filter { filteredActions.contains($0) }
        groups["View"] = view.filter { filteredActions.contains($0) }
        groups["Tabs"] = tabs.filter { filteredActions.contains($0) }
        groups["Other"] = other.filter { filteredActions.contains($0) }
        
        return groups.filter { !$0.value.isEmpty }
    }
}
