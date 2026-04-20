import AppKit
import SwiftUI

struct RemoteCloudBrowserView: View {
    @Binding var currentPath: URL
    let searchText: String
    let workspace: CloudWorkspaceModel

    @StateObject private var cloudWorkspace = CloudWorkspaceStore.shared
    @State private var items: [CloudFileItem] = []
    @State private var isLoading = false
    @State private var isOpeningFile = false
    @State private var errorMessage: String?

    private var location: (account: CloudDriveAccount, itemID: String?, displayPath: String, ancestors: [String])? {
        cloudWorkspace.resolveRemoteLocation(for: currentPath)
    }

    private var filteredItems: [CloudFileItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if workspace.accounts.isEmpty {
                ContentUnavailableView(
                    "No Cloud Drives",
                    systemImage: "icloud.slash",
                    description: Text("Add a cloud account in Settings to browse it here.")
                )
            } else if let location {
                browser(for: location)
            } else {
                accountChooser
            }
        }
        .task(id: currentPath) {
            await loadCurrentLocation()
        }
    }

    @ViewBuilder
    private func browser(for location: (account: CloudDriveAccount, itemID: String?, displayPath: String, ancestors: [String])) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(location.account.displayName, systemImage: location.account.provider.systemImage)
                        .font(.headline)
                    Text(location.displayPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let localRoot = location.account.localRootURL,
                   FileManager.default.fileExists(atPath: localRoot.path) {
                    Button("Reveal Sync Folder") {
                        NSWorkspace.shared.open(localRoot)
                    }
                }

                if location.account.supportsRemoteBrowsing && location.account.hasRemoteConfiguration {
                    Button(cloudWorkspace.isRemotelyAuthenticated(location.account) ? "Refresh" : "Connect") {
                        Task {
                            await connectAndReload(accountID: location.account.id)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading cloud folder…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Cloud Folder Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if filteredItems.isEmpty {
                ContentUnavailableView(
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty Folder" : "No Matching Items",
                    systemImage: "folder",
                    description: Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "This cloud folder does not contain any items yet." : "Try a different search query.")
                )
            } else {
                List(filteredItems) { item in
                    Button {
                        handleSelection(of: item, in: location)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .lineLimit(1)
                                Text(item.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpeningFile)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var accountChooser: some View {
        List {
            Section("Cloud Accounts") {
                ForEach(workspace.accounts) { account in
                    Button {
                        currentPath = account.browseURL
                    } label: {
                        HStack {
                            Label(account.displayName, systemImage: account.provider.systemImage)
                            Spacer()
                            Text(cloudWorkspace.authenticationLabel(for: account))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func loadCurrentLocation() async {
        guard let location else {
            items = []
            errorMessage = nil
            return
        }

        guard let service = cloudWorkspace.service(for: location.account) else {
            items = []
            errorMessage = location.account.provider == .iCloudDrive
                ? "iCloud Drive still uses the local filesystem path instead of a remote API."
                : "This account is missing a remote provider service."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            items = try await service.listFiles(path: location.itemID ?? "")
                .sorted {
                    if $0.isDirectory != $1.isDirectory {
                        return $0.isDirectory && !$1.isDirectory
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    private func connectAndReload(accountID: UUID) async {
        do {
            try await cloudWorkspace.connectAccount(accountID)
            await loadCurrentLocation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleSelection(of item: CloudFileItem, in location: (account: CloudDriveAccount, itemID: String?, displayPath: String, ancestors: [String])) {
        if item.isDirectory {
            let nextPath = location.displayPath == location.account.rootName
                ? "\(location.account.rootName)/\(item.name)"
                : "\(location.displayPath)/\(item.name)"
            let nextAncestors = location.ancestors + (location.itemID.map { [$0] } ?? [])
            currentPath = cloudWorkspace.remoteURL(
                for: location.account,
                itemID: item.path,
                displayPath: nextPath,
                ancestors: nextAncestors
            )
            return
        }

        Task {
            await openFile(item, in: location.account)
        }
    }

    private func openFile(_ file: CloudFileItem, in account: CloudDriveAccount) async {
        guard let service = cloudWorkspace.service(for: account) else { return }

        isOpeningFile = true
        defer { isOpeningFile = false }

        let baseName = file.name.isEmpty ? "download" : file.name
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(baseName)

        do {
            try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await service.downloadFile(file, to: tempURL)
            NSWorkspace.shared.open(tempURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
