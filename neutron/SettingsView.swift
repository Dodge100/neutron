import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            KeyboardShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            TagsSettingsView()
                .tabItem {
                    Label("Tags", systemImage: "tag")
                }

            CloudManagementSettingsView()
                .tabItem {
                    Label("Cloud", systemImage: "cloud")
                }

            SidebarSettingsView()
                .tabItem {
                    Label("Sidebar", systemImage: "sidebar.left")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("openInTabs") private var openInTabs = true
    @AppStorage("defaultPath") private var defaultPath: String = "Home"
    @AppStorage("iconSize") private var iconSize: Double = 48
    @AppStorage("showSizeColumn") private var showSizeColumn = true
    @AppStorage("showDateColumn") private var showDateColumn = true
    @AppStorage("showKindColumn") private var showKindColumn = true
    @AppStorage("showPathBarInPanes") private var showPathBarInPanes = true
    @AppStorage("showStatusBarInPanes") private var showStatusBarInPanes = true
    @AppStorage("syncPaneViewModes") private var syncPaneViewModes = false
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true
    @AppStorage("downloadDefaultPath") private var downloadDefaultPath: String = ""

    @State private var showDownloadFolderPicker = false

    private let startupLocations = SidebarDataProvider.availableStartLocations()

    private var downloadFolderURL: URL {
        if !downloadDefaultPath.isEmpty {
            return URL(fileURLWithPath: downloadDefaultPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var body: some View {
        Form {
            Section("New Windows") {
                Picker("Open at", selection: $defaultPath) {
                    ForEach(startupLocations, id: \.value) { location in
                        Text(location.title).tag(location.value)
                    }
                }

                Toggle("Prefer tabs over separate windows", isOn: $openInTabs)
                Toggle("Show path bar in panes", isOn: $showPathBarInPanes)
                Toggle("Show status bar in panes", isOn: $showStatusBarInPanes)
                Toggle("Sync pane view modes", isOn: $syncPaneViewModes)
                Toggle("Ask before moving items to Trash", isOn: $confirmBeforeDelete)
            }

            Section("Downloads") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default save location")
                        Text(downloadFolderURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { showDownloadFolderPicker = true }
                }
            }

            Section("Icon View") {
                HStack {
                    Text("Icon size")
                    Slider(value: $iconSize, in: 48...96, step: 4)
                    Text("\(Int(iconSize))")
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section("List Columns") {
                Toggle("Show Size", isOn: $showSizeColumn)
                Toggle("Show Date Modified", isOn: $showDateColumn)
                Toggle("Show Kind", isOn: $showKindColumn)
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showDownloadFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                downloadDefaultPath = url.path
            }
        }
    }
}

struct TagsSettingsView: View {
    @State private var tags: [String] = []

    var body: some View {
        Form {
            Section("Discovered Tags") {
                if tags.isEmpty {
                    Text("No tags found yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(tagColor(for: tag))
                                .frame(width: 8, height: 8)
                            Text(tag)
                        }
                    }
                }
            }

            Section("Info") {
                Text("Tags come from your existing Finder tags and update automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshTags)
    }

    private func refreshTags() {
        DispatchQueue.global(qos: .utility).async {
            let discovered = SidebarDataProvider.discoveredTags()
            DispatchQueue.main.async {
                tags = discovered
            }
        }
    }
}

struct CloudManagementSettingsView: View {
    var body: some View {
        CloudDriveManagementView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
    }
}

struct SidebarSettingsView: View {
    @AppStorage("showFavorites") private var showFavorites = true
    @AppStorage("showiCloud") private var showiCloud = true
    @AppStorage("showLocations") private var showLocations = true
    @AppStorage("showTags") private var showTags = true
    @AppStorage("showCloud") private var showCloud = true

    var body: some View {
        Form {
            Section("Sidebar Sections") {
                Toggle("Favorites", isOn: $showFavorites)
                Toggle("iCloud", isOn: $showiCloud)
                Toggle("Locations", isOn: $showLocations)
                Toggle("Cloud Accounts", isOn: $showCloud)
                Toggle("Tags", isOn: $showTags)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("showHiddenByDefault") private var showHiddenByDefault = false

    var body: some View {
        Form {
            Section("Visibility") {
                Toggle("Show hidden files by default", isOn: $showHiddenByDefault)
            }
        }
        .formStyle(.grouped)
    }
}
