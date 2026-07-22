import Foundation

enum QueueMoveAction: String, Codable, CaseIterable {
    case top
    case up
    case down
    case bottom
}

enum DownloadPriority: Int, Codable, CaseIterable, Identifiable {
    case low = 0
    case normal = 1
    case high = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

struct DownloadQueueOrder: Codable, Equatable {
    private(set) var orderedIDs: [UUID] = []

    mutating func insertIfNeeded(_ id: UUID) {
        guard !orderedIDs.contains(id) else { return }
        orderedIDs.append(id)
    }

    mutating func remove(_ id: UUID) {
        orderedIDs.removeAll { $0 == id }
    }

    mutating func move(_ id: UUID, action: QueueMoveAction) {
        guard let index = orderedIDs.firstIndex(of: id) else { return }

        switch action {
        case .top:
            orderedIDs.remove(at: index)
            orderedIDs.insert(id, at: 0)
        case .bottom:
            orderedIDs.remove(at: index)
            orderedIDs.append(id)
        case .up:
            guard index > 0 else { return }
            orderedIDs.swapAt(index, index - 1)
        case .down:
            guard index < orderedIDs.count - 1 else { return }
            orderedIDs.swapAt(index, index + 1)
        }
    }

    func sorted<T: Identifiable>(_ items: [T], fallback: (T, T) -> Bool) -> [T] where T.ID == UUID {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        return items.sorted { lhs, rhs in
            let left = rank[lhs.id] ?? Int.max
            let right = rank[rhs.id] ?? Int.max
            if left == right {
                return fallback(lhs, rhs)
            }
            return left < right
        }
    }
}

struct DownloadPriorityQueueSorter {
    static func sort<T: Identifiable>(
        _ items: [T],
        priority: (T) -> DownloadPriority,
        queueOrder: DownloadQueueOrder,
        fallback: (T, T) -> Bool
    ) -> [T] where T.ID == UUID {
        let high = queueOrder.sorted(items.filter { priority($0) == .high }, fallback: fallback)
        let normal = queueOrder.sorted(items.filter { priority($0) == .normal }, fallback: fallback)
        let low = queueOrder.sorted(items.filter { priority($0) == .low }, fallback: fallback)
        return high + normal + low
    }
}

struct DownloadStartPolicy {
    static func canStart(pauseModeEnabled: Bool, scheduledAt: Date?, now: Date = Date()) -> Bool {
        guard !pauseModeEnabled else { return false }
        guard let scheduledAt else { return true }
        return scheduledAt <= now
    }
}

struct DownloadLinkGrabber {
    static func resolvedDownloadURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased(),
           ["http", "https", "ftp"].contains(scheme),
           parsed.host != nil {
            return parsed
        }

        if let inferred = URL(string: "https://\(trimmed)"), inferred.host != nil {
            return inferred
        }

        return nil
    }

    static func extractLinks(from text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s\"'<>]+"#, options: [.caseInsensitive]) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)

        var seen = Set<String>()
        var urls: [URL] = []

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            var raw = String(text[range])
            while let last = raw.last, ".,);]".contains(last) {
                raw.removeLast()
            }

            guard let url = resolvedDownloadURL(from: raw) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }

        return urls
    }

    static func destinationURL(for sourceURL: URL, baseDirectory: URL, existingPaths: Set<String> = []) -> URL {
        let fileName = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
        let destination = baseDirectory.appendingPathComponent(fileName)
        let exists: (URL) -> Bool = { url in
            existingPaths.contains(url.path) || FileManager.default.fileExists(atPath: url.path)
        }

        guard exists(destination) else { return destination }

        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent

        var counter = 2
        let maxAttempts = 1000
        while counter <= maxAttempts {
            let candidateName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let candidate = baseDirectory.appendingPathComponent(candidateName)
            if !exists(candidate) {
                return candidate
            }
            counter += 1
        }
        let fallbackSuffix = UUID().uuidString.prefix(8)
        let fallbackName = ext.isEmpty ? "\(base) (\(fallbackSuffix))" : "\(base) (\(fallbackSuffix)).\(ext)"
        return baseDirectory.appendingPathComponent(fallbackName)
    }
}

struct DownloadDuplicatePolicy {
    static func filterIncomingURLs(
        _ urls: [URL],
        existingAbsoluteURLs: Set<String>,
        preventDuplicates: Bool
    ) -> [URL] {
        let uniqueIncoming = deduplicated(urls)
        guard preventDuplicates else { return uniqueIncoming }

        return uniqueIncoming.filter { !existingAbsoluteURLs.contains($0.absoluteString) }
    }

    static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}

struct DownloadFileNameTemplate {
    static func apply(
        destination: URL,
        sourceURL: URL,
        prefixTemplate: String,
        suffixTemplate: String,
        now: Date = Date()
    ) -> URL {
        let baseDirectory = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent

        let prefix = render(prefixTemplate, sourceURL: sourceURL, now: now)
        let suffix = render(suffixTemplate, sourceURL: sourceURL, now: now)
        let newStem = "\(prefix)\(stem)\(suffix)"

        let fileName = ext.isEmpty ? newStem : "\(newStem).\(ext)"
        return baseDirectory.appendingPathComponent(fileName)
    }

    private static func render(_ template: String, sourceURL: URL, now: Date) -> String {
        guard !template.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return template
            .replacingOccurrences(of: "{host}", with: sourceURL.host ?? "")
            .replacingOccurrences(of: "{date}", with: formatter.string(from: now))
    }
}

struct DownloadSchedulePolicy {
    static func scheduledDate(defaultDelayMinutes: Int, now: Date = Date()) -> Date? {
        guard defaultDelayMinutes > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(defaultDelayMinutes * 60))
    }
}

struct DownloadHistoryCleanup {
    static func prune<T>(
        records: [T],
        keepingDays: Int,
        date: (T) -> Date,
        now: Date = Date()
    ) -> [T] {
        guard keepingDays > 0 else { return records }
        let threshold = now.addingTimeInterval(-TimeInterval(keepingDays * 24 * 60 * 60))
        return records.filter { date($0) >= threshold }
    }
}

struct DownloadSearchMatcher {
    static func matches(query: String, values: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
        return values.contains { $0.lowercased().contains(lowered) }
    }
}

struct DownloadPackagizerRule: Codable, Identifiable, Equatable {
    let id: UUID
    var isEnabled: Bool
    var hostPattern: String?
    var fileNameRegex: String?
    var fileNameReplacement: String?
    var subdirectoryTemplate: String?
    var packageNameTemplate: String?

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        hostPattern: String? = nil,
        fileNameRegex: String? = nil,
        fileNameReplacement: String? = nil,
        subdirectoryTemplate: String? = nil,
        packageNameTemplate: String? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.hostPattern = hostPattern
        self.fileNameRegex = fileNameRegex
        self.fileNameReplacement = fileNameReplacement
        self.subdirectoryTemplate = subdirectoryTemplate
        self.packageNameTemplate = packageNameTemplate
    }
}

struct DownloadPackagizerResult: Equatable {
    var destination: URL
    var packageNameOverride: String?
}

enum DownloadPackagizer {
    static func apply(url: URL, destination: URL, rules: [DownloadPackagizerRule]) -> DownloadPackagizerResult {
        var currentDestination = destination
        var packageOverride: String?

        for rule in rules where rule.isEnabled {
            guard matchesHost(url: url, pattern: rule.hostPattern) else { continue }

            var fileName = currentDestination.lastPathComponent
            if let regexPattern = rule.fileNameRegex,
               let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]),
               let replacement = rule.fileNameReplacement {
                let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
                fileName = regex.stringByReplacingMatches(in: fileName, options: [], range: range, withTemplate: renderTemplate(replacement, url: url, destination: currentDestination))
            }

            if fileName != currentDestination.lastPathComponent {
                currentDestination = currentDestination.deletingLastPathComponent().appendingPathComponent(fileName)
            }

            if let subdirectoryTemplate = rule.subdirectoryTemplate {
                let subdirectory = renderTemplate(subdirectoryTemplate, url: url, destination: currentDestination)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !subdirectory.isEmpty {
                    currentDestination = currentDestination.deletingLastPathComponent()
                        .appendingPathComponent(subdirectory, isDirectory: true)
                        .appendingPathComponent(currentDestination.lastPathComponent)
                }
            }

            if let packageNameTemplate = rule.packageNameTemplate {
                let rendered = renderTemplate(packageNameTemplate, url: url, destination: currentDestination)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rendered.isEmpty {
                    packageOverride = rendered
                }
            }
        }

        return DownloadPackagizerResult(destination: currentDestination, packageNameOverride: packageOverride)
    }

    private static func matchesHost(url: URL, pattern: String?) -> Bool {
        guard let pattern, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let host = url.host ?? ""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(host.startIndex..<host.endIndex, in: host)
        return regex.firstMatch(in: host, options: [], range: range) != nil
    }

    private static func renderTemplate(_ template: String, url: URL, destination: URL) -> String {
        let filename = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        return template
            .replacingOccurrences(of: "{host}", with: url.host ?? "")
            .replacingOccurrences(of: "{filename}", with: filename)
            .replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "{path}", with: url.path)
    }
}

struct DownloadSegmentPlanner {
    static func preferredChunkSize(totalBytes: Int64, connectionsPerDownload: Int, minimumSegmentSize: Int64 = 2 * 1024 * 1024) -> Int64 {
        let floor = max(minimumSegmentSize, 4 * 1024 * 1024)
        let target = max(floor, totalBytes / Int64(max(connectionsPerDownload * 3, 1)))
        return min(max(target, floor), 32 * 1024 * 1024)
    }

    static func buildRanges(totalBytes: Int64, chunkSize: Int64) -> [ClosedRange<Int64>] {
        guard totalBytes > 0 else { return [] }
        var result: [ClosedRange<Int64>] = []
        var start: Int64 = 0

        while start < totalBytes {
            let end = min(totalBytes - 1, start + max(chunkSize, 1) - 1)
            result.append(start...end)
            start = end + 1
        }

        return result
    }
}

protocol DownloadProcessRunning {
    @discardableResult
    func run(executableURL: URL, arguments: [String]) throws -> Int32
}

struct SystemDownloadProcessRunner: DownloadProcessRunning {
    @discardableResult
    func run(executableURL: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum DownloadArchiveExtractor {
    static func extractIfNeeded(
        sourceFileURL: URL,
        destinationDirectory: URL,
        isEnabled: Bool,
        processRunner: DownloadProcessRunning = SystemDownloadProcessRunner()
    ) throws -> Bool {
        guard isEnabled else { return false }
        guard sourceFileURL.pathExtension.lowercased() == "zip" else { return false }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let status = try processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-o", sourceFileURL.path, "-d", destinationDirectory.path]
        )
        return status == 0
    }
}
