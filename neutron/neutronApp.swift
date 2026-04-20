//
//  neutronApp.swift
//  neutron
//
//  Created by Dodge1 on 10/31/25.
//

import SwiftUI

@main
struct neutronApp: App {
    init() {
        MCPTaskManager.shared.taskProvider = DownloadManagerProvider.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Folder") {
                    NotificationCenter.default.post(name: .createNewFolder, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    NotificationCenter.default.post(name: .selectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Duplicate") {
                    NotificationCenter.default.post(name: .duplicateFiles, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Hidden Files") {
                    NotificationCenter.default.post(name: .toggleHiddenFiles, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Split Horizontally") {
                    NotificationCenter.default.post(name: .splitPaneHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Split Vertically") {
                    NotificationCenter.default.post(name: .splitPaneVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("as Icons") {
                    NotificationCenter.default.post(name: .setViewMode, object: "icon")
                }
                .keyboardShortcut("1", modifiers: [.command, .control])

                Button("as List") {
                    NotificationCenter.default.post(name: .setViewMode, object: "list")
                }
                .keyboardShortcut("2", modifiers: [.command, .control])

                Button("as Columns") {
                    NotificationCenter.default.post(name: .setViewMode, object: "column")
                }
                .keyboardShortcut("3", modifiers: [.command, .control])
            }

            CommandMenu("Tabs") {
                Button("Select Tab 1") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Select Tab 2") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Select Tab 3") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Select Tab 4") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Select Tab 5") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Select Tab 6") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Select Tab 7") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                Button("Select Tab 8") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 7) }
                    .keyboardShortcut("8", modifiers: .command)
                Button("Select Tab 9") { NotificationCenter.default.post(name: .selectTabAtIndex, object: 8) }
                    .keyboardShortcut("9", modifiers: .command)

                Divider()

                Button("Select Tab 1 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 0) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Select Tab 2 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 1) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Select Tab 3 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 2) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("Select Tab 4 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 3) }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Button("Select Tab 5 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 4) }
                    .keyboardShortcut("5", modifiers: [.command, .option])
                Button("Select Tab 6 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 5) }
                    .keyboardShortcut("6", modifiers: [.command, .option])
                Button("Select Tab 7 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 6) }
                    .keyboardShortcut("7", modifiers: [.command, .option])
                Button("Select Tab 8 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 7) }
                    .keyboardShortcut("8", modifiers: [.command, .option])
                Button("Select Tab 9 in Other Pane") { NotificationCenter.default.post(name: .selectTabAtIndexInOtherPane, object: 8) }
                    .keyboardShortcut("9", modifiers: [.command, .option])
            }

            CommandMenu("Go") {
                Button("Back") {
                    NotificationCenter.default.post(name: .navigateBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: .navigateForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Enclosing Folder") {
                    NotificationCenter.default.post(name: .goToParentFolder, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Open Selected") {
                    NotificationCenter.default.post(name: .openSelectedItem, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Divider()

                Button("Home") {
                    NotificationCenter.default.post(name: .goHome, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Desktop") {
                    NotificationCenter.default.post(name: .goDesktop, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option, .shift])

                Button("Downloads") {
                    NotificationCenter.default.post(name: .goDownloads, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Button("Documents") {
                    NotificationCenter.default.post(name: .goDocuments, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Go to Folder…") {
                    NotificationCenter.default.post(name: .goToFolder, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
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

                Button("Open Terminal Here") {
                    NotificationCenter.default.post(name: .openInTerminal, object: nil)
                }
                .keyboardShortcut("`", modifiers: .command)
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
