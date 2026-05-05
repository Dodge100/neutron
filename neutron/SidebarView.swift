//
//  Sidebar.swift
//  neutron
//
//  Created by Dodge1 on 11/1/25.
//

import SwiftUI
import Combine

struct SidebarView: View {
    @Binding var selectedPath: URL?

    @State private var externalVolumes: [URL] = []
    @State private var finderTags: [FinderTag] = []
    @StateObject private var cloudWorkspace = CloudWorkspaceStore.shared
    @StateObject private var favoritesStore = FavoritesStore.shared
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
        var items: [(label: String, systemImage: String, url: URL)] = [
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

        // Append user custom favorites
        for fav in favoritesStore.favorites {
            let exists = FileManager.default.fileExists(atPath: fav.path)
            guard exists else { continue }
            guard !items.contains(where: { $0.url == fav }) else { continue }
            items.append((fav.lastPathComponent, "folder", fav))
        }

        return items
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
                        .contextMenu {
                            if favoritesStore.isFavorite(item.url) {
                                Button("Remove from Favorites") {
                                    favoritesStore.removeFavorite(item.url)
                                }
                            }
                            Button("Show in Finder") {
                                if item.url.isFileURL {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.url.path)
                                }
                            }
                        }
                }

                // Drop target to add favorites
            }
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        favoritesStore.addFavorite(url)
                    }
                }
                return !urls.isEmpty
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

// MARK: - FavoritesStore

class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published var favorites: [URL] = []

    private let key = "userFavoritePaths"

    init() {
        load()
    }

    func addFavorite(_ url: URL) {
        guard !favorites.contains(url) else { return }
        favorites.append(url)
        save()
    }

    func removeFavorite(_ url: URL) {
        favorites.removeAll { $0 == url }
        save()
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains(url)
    }

    private func save() {
        let paths = favorites.map(\.path)
        UserDefaults.standard.set(paths, forKey: key)
    }

    private func load() {
        guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return }
        favorites = paths.map { URL(fileURLWithPath: $0) }
    }
}
