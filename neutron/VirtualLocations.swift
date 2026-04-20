import Foundation

enum VirtualLocation {
    nonisolated static let recentsURL = URL(string: "neutron-recents://local")!

    nonisolated static func isRecents(_ url: URL) -> Bool {
        url.scheme == "neutron-recents"
    }

    nonisolated static func tagURL(named tagName: String) -> URL {
        var components = URLComponents()
        components.scheme = "neutron-tag"
        components.host = "local"
        components.queryItems = [URLQueryItem(name: "name", value: tagName)]
        return components.url ?? URL(string: "neutron-tag://local")!
    }

    nonisolated static func tagName(for url: URL) -> String? {
        guard url.scheme == "neutron-tag",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?
            .first(where: { $0.name == "name" })?
            .value?
            .removingPercentEncoding
    }

    nonisolated static func displayName(for url: URL) -> String {
        if isRecents(url) {
            return "Recents"
        }
        if let tagName = tagName(for: url) {
            return tagName
        }
        if url.isFileURL {
            if url.path == NSHomeDirectory() {
                return "Home"
            }
            if url.path == "/" {
                return "Macintosh HD"
            }
        }
        return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
    }
}

enum SidebarDataProvider {
    nonisolated static func recentFiles(limit: Int = 150) -> [FileItem] {
        scanFiles(maxVisited: 4000) { _ in true }
            .sorted(by: recencySort)
            .prefix(limit)
            .map { $0 }
    }

    nonisolated static func taggedFiles(named tagName: String, limit: Int = 300) -> [FileItem] {
        scanFiles(maxVisited: 4000) { item in
            item.tags.contains { $0.caseInsensitiveCompare(tagName) == .orderedSame }
        }
        .sorted(by: recencySort)
        .prefix(limit)
        .map { $0 }
    }

    nonisolated static func discoveredTags(limit: Int = 24) -> [String] {
        var counts: [String: Int] = [:]
        _ = scanFiles(maxVisited: 4000) { item in
            for tag in item.tags where !tag.isEmpty {
                counts[tag, default: 0] += 1
            }
            return false
        }

        return counts
            .sorted {
                if $0.value == $1.value {
                    return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map(\.key)
    }

    nonisolated static func availableStartLocations() -> [(value: String, title: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, String, URL?)] = [
            ("Home", "Home", home),
            ("Recents", "Recents", recentsURL),
            ("Desktop", "Desktop", home.appendingPathComponent("Desktop")),
            ("Documents", "Documents", home.appendingPathComponent("Documents")),
            ("Downloads", "Downloads", home.appendingPathComponent("Downloads")),
        ]

        return candidates.compactMap { value, title, url in
            guard let url else { return nil }
            if VirtualLocation.isRecents(url) || FileManager.default.fileExists(atPath: url.path) {
                return (value, title)
            }
            return nil
        }
    }

    nonisolated private static var recentsURL: URL {
        VirtualLocation.recentsURL
    }

    nonisolated private static func recencySort(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        max(lhs.created, lhs.modified) > max(rhs.created, rhs.modified)
    }

    nonisolated private static func scanFiles(maxVisited: Int, matching predicate: (FileItem) -> Bool) -> [FileItem] {
        var results: [FileItem] = []
        var visited = 0
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .tagNamesKey,
            .isPackageKey,
        ]

        outer: for root in searchRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                do {
                    let values = try url.resourceValues(forKeys: resourceKeys)
                    guard values.isRegularFile ?? false,
                          let item = FileItem.fromURL(url, values: values) else {
                        continue
                    }

                    visited += 1
                    if visited >= maxVisited {
                        break outer
                    }

                    if predicate(item) {
                        results.append(item)
                    }
                } catch {
                    continue
                }
            }
        }

        return results
    }

    nonisolated private static func searchRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Movies"),
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Pictures"),
        ]

        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
