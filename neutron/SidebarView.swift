//
//  Sidebar.swift
//  neutron
//
//  Created by Dodge1 on 11/1/25.
//

import SwiftUI

struct SidebarView: View {
    @Binding var selectedPath: URL?

    @State private var externalVolumes: [URL] = []
    @State private var finderTags: [FinderTag] = []
    @StateObject private var cloudWorkspace = CloudWorkspaceStore.shared
    @AppStorage("showFavorites") private var showFavorites = true
    @AppStorage("showiCloud") private var showiCloud = true
    @AppStorage("showLocations") private var showLocations = true
    @AppStorage("showCloud") private var showCloud = true
    @AppStorage("showTags") private var showTags = true

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser

    private struct FinderTag: Identifiable {
        let name: String
        let color: Color
        var id: String { name }
    }

    private var favoriteItems: [(label: String, systemImage: String, url: URL)] {
        [
            ("Recents", "clock", VirtualLocation.recentsURL),
            ("Applications", "app.dashed", URL(fileURLWithPath: "/Applications")),
            ("Desktop", "desktopcomputer", homeDir.appendingPathComponent("Desktop")),
            ("Documents", "doc", homeDir.appendingPathComponent("Documents")),
            ("Downloads", "arrow.down.circle", homeDir.appendingPathComponent("Downloads")),
            ("Home", "house", homeDir),
            ("Movies", "film", homeDir.appendingPathComponent("Movies")),
            ("Music", "music.note", homeDir.appendingPathComponent("Music")),
            ("Pictures", "photo", homeDir.appendingPathComponent("Pictures")),
        ].filter { item in
            VirtualLocation.isRecents(item.url) || FileManager.default.fileExists(atPath: item.url.path)
        }
    }

    private var hasICloudDrive: Bool {
        FileManager.default.fileExists(atPath: homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }

    var body: some View {
        List(selection: $selectedPath) {
            // MARK: - Favorites
            if showFavorites {
            Section("Favorites") {
                ForEach(favoriteItems, id: \.url) { item in
                    Label(item.label, systemImage: item.systemImage)
                        .tag(item.url)
                }
            }
            }

            // MARK: - iCloud
            if showiCloud && hasICloudDrive {
            Section("iCloud") {
                Label("iCloud Drive", systemImage: "icloud")
                    .tag(homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
            }
            }

            // MARK: - Locations
            if showLocations {
            Section("Locations") {
                Label("Macintosh HD", systemImage: "internaldrive")
                    .tag(URL(fileURLWithPath: "/"))

                ForEach(externalVolumes, id: \.self) { volume in
                    HStack {
                        Label(volume.lastPathComponent, systemImage: "externaldrive")
                        Spacer()
                        Button {
                            ejectVolume(volume)
                        } label: {
                            Image(systemName: "eject")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Eject \(volume.lastPathComponent)")
                    }
                    .tag(volume)
                }

                Label("Network", systemImage: "network")
                    .tag(URL(fileURLWithPath: "/Network"))
            }
            }

            // MARK: - Cloud
            if showCloud && !cloudWorkspace.model.accounts.isEmpty {
            Section("Cloud") {
                ForEach(cloudWorkspace.model.accounts) { account in
                    Label(account.displayName, systemImage: account.provider.systemImage)
                        .tag(cloudWorkspace.browseURL(for: account))
                }
            }
            }

            // MARK: - Tags
            if showTags && !finderTags.isEmpty {
            Section("Tags") {
                ForEach(finderTags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 10, height: 10)
                    }
                    .tag(VirtualLocation.tagURL(named: tag.name))
                }
            }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 170)
        .onAppear {
            refreshVolumes()
            cloudWorkspace.refreshAccountConnections()
            refreshFinderTags()
        }
    }

    private func ejectVolume(_ volume: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            refreshVolumes()
            if selectedPath == volume {
                selectedPath = FileManager.default.homeDirectoryForCurrentUser
            }
        } catch {
            // Volume could not be ejected
        }
    }
    
    private func refreshVolumes() {
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isVolumeKey],
            options: .skipsHiddenFiles
        ) else { return }

        let bootVolume = volumesURL.appendingPathComponent("Macintosh HD")
        externalVolumes = contents.filter { $0 != bootVolume }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func refreshFinderTags() {
        DispatchQueue.global(qos: .utility).async {
            let tags = SidebarDataProvider.discoveredTags().map {
                FinderTag(name: $0, color: tagColor(for: $0))
            }

            DispatchQueue.main.async {
                self.finderTags = tags
            }
        }
    }
}
