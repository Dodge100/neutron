//
//  neutronApp.swift
//  neutron
//
//  Created by Dodge1 on 10/31/25.
//

import SwiftUI

@main
struct neutronApp: App {
    @StateObject private var shortcutManager = ShortcutManager.shared

    init() {
        MCPTaskManager.shared.taskProvider = DownloadManagerProvider.shared
    }

    @ViewBuilder
    private func shortcutCommand(_ title: String, action: ShortcutAction) -> some View {
        Button(title) {
            action.trigger()
        }
        .applyingShortcut(shortcutManager.shortcut(for: action))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                shortcutCommand("New Folder", action: .newFolder)

                Divider()

                shortcutCommand("New Tab", action: .newTab)
                shortcutCommand("Close Tab", action: .closeTab)
            }

            CommandGroup(after: .pasteboard) {
                shortcutCommand("Select All", action: .selectAll)
                shortcutCommand("Duplicate", action: .duplicate)
            }

            CommandGroup(after: .toolbar) {
                shortcutCommand("Toggle Hidden Files", action: .toggleHidden)

                Divider()

                shortcutCommand("Split Horizontally", action: .splitPaneHorizontal)
                shortcutCommand("Split Vertically", action: .splitPaneVertical)

                Divider()

                shortcutCommand("as Icons", action: .viewAsIcons)
                shortcutCommand("as List", action: .viewAsList)
                shortcutCommand("as Columns", action: .viewAsColumns)
            }

            CommandMenu("Go") {
                shortcutCommand("Back", action: .goBack)
                shortcutCommand("Forward", action: .goForward)
                shortcutCommand("Enclosing Folder", action: .goUp)

                Button("Open Selected") {
                    NotificationCenter.default.post(name: .openSelectedItem, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Divider()

                shortcutCommand("Home", action: .goHome)
                shortcutCommand("Desktop", action: .goDesktop)
                shortcutCommand("Downloads", action: .goDownloads)
                shortcutCommand("Documents", action: .goDocuments)

                Divider()

                shortcutCommand("Go to Folder…", action: .goToFolder)
            }

            CommandMenu("Tools") {
                Button("Downloads…") {
                    NotificationCenter.default.post(name: .showDownloadsPanel, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .option])

                Button("Download Video URL…") {
                    NotificationCenter.default.post(name: .showVideoDownload, object: nil)
                }

                Button("Add Magnet Link…") {
                    NotificationCenter.default.post(name: .showTorrentMagnet, object: nil)
                }

                Button("Add Torrent File…") {
                    NotificationCenter.default.post(name: .showTorrentFilePicker, object: nil)
                }

                Divider()

                shortcutCommand("Open Terminal Here", action: .openTerminal)
            }
        }

        Settings {
            SettingsView()
        }

        // Downloads panel window
        Window("Downloads", id: "downloads") {
            TransferCenterView()
        }
        .defaultSize(width: 520, height: 620)
    }
}

extension Notification.Name {
    static let newTab = Notification.Name("newTab")
    static let closeTab = Notification.Name("closeTab")
    static let createNewFolder = Notification.Name("createNewFolder")
    static let createNewFile = Notification.Name("createNewFile")
    static let toggleHiddenFiles = Notification.Name("toggleHiddenFiles")
    static let goToParentFolder = Notification.Name("goToParentFolder")
    static let openSelectedItem = Notification.Name("openSelectedItem")
    static let selectAll = Notification.Name("selectAll")
    static let duplicateFiles = Notification.Name("duplicateFiles")
    static let setViewMode = Notification.Name("setViewMode")
    static let navigateBack = Notification.Name("navigateBack")
    static let navigateForward = Notification.Name("navigateForward")
    static let goHome = Notification.Name("goHome")
    static let goDesktop = Notification.Name("goDesktop")
    static let goDownloads = Notification.Name("goDownloads")
    static let goDocuments = Notification.Name("goDocuments")
    static let goToFolder = Notification.Name("goToFolder")
    static let showDownloadsPanel = Notification.Name("neutron.showDownloadsPanel")
    static let showVideoDownload = Notification.Name("neutron.showVideoDownload")
    static let showTorrentMagnet = Notification.Name("neutron.showTorrentMagnet")
    static let showTorrentFilePicker = Notification.Name("neutron.showTorrentFilePicker")
    static let splitPaneHorizontal = Notification.Name("neutron.splitPaneHorizontal")
    static let splitPaneVertical = Notification.Name("neutron.splitPaneVertical")
    static let selectTabAtIndex = Notification.Name("neutron.selectTabAtIndex")
    static let selectTabAtIndexInOtherPane = Notification.Name("neutron.selectTabAtIndexInOtherPane")
}
