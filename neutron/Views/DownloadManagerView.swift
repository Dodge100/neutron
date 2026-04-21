import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers

struct DownloadManagerPanelView: View {
    @StateObject private var downloadManager = DownloadManager.shared

    @State private var showFilePicker = false
    @State private var downloadURL = ""
    @State private var selectedDestination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @State private var activeTab = 0
    @State private var inputError: String?

    @State private var linkGrabberInput = ""
    @State private var grabbedURLs: [URL] = []
    @State private var monitorClipboard = true
    @State private var clipboardChangeCount = NSPasteboard.general.changeCount
    @State private var lastAutoImportedLink: String?

    private let clipboardTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    private var queueTasks: [DownloadTask] { downloadManager.queuedTasks }
    private var runningTasks: [DownloadTask] { downloadManager.runningTasks }
    private var failedTasks: [DownloadTask] { downloadManager.failedTasks }

    private var knownSources: [String] {
        downloadManager.knownSources()
    }

    private var unlimitedBinding: Binding<Bool> {
        Binding(
            get: { downloadManager.speedLimitBytesPerSecond == 0 },
            set: { unlimited in
                if unlimited {
                    downloadManager.speedLimitBytesPerSecond = 0
                } else if downloadManager.speedLimitBytesPerSecond == 0 {
                    downloadManager.speedLimitBytesPerSecond = 2 * 1024 * 1024
                }
            }
        )
    }

    private var speedLimitBinding: Binding<Int64> {
        Binding(
            get: { max(downloadManager.speedLimitBytesPerSecond, 256 * 1024) },
            set: { newValue in
                downloadManager.speedLimitBytesPerSecond = min(max(newValue, 256 * 1024), 100 * 1024 * 1024)
            }
        )
    }

    private var canStartDownload: Bool {
        resolvedDownloadURL(from: downloadURL) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickAddSection
            managerControls
            sourceLimitsSection

            if let inputError {
                Text(inputError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("View", selection: $activeTab) {
                Text("Queue (\(queueTasks.count))").tag(0)
                Text("Running (\(runningTasks.count))").tag(1)
                Text("Paused (\(downloadManager.pausedTasks.count))").tag(2)
                Text("Done (\(downloadManager.completedTasks.count))").tag(3)
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(spacing: 8) {
                    switch activeTab {
                    case 0:
                        queueList
                    case 1:
                        runningList
                    case 2:
                        pausedList
                    case 3:
                        completedList
                    default:
                        EmptyView()
                    }
                }
            }
            .frame(minHeight: 220)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 520)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedDestination = url
            }
        }
        .onReceive(clipboardTimer) { _ in
            handleClipboardImportTick()
        }
        .onAppear {
            if !FileManager.default.fileExists(atPath: selectedDestination.path) {
                selectedDestination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download Center")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("JD-style queueing, chunked downloads, resume data persistence, and per-source traffic controls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Clipboard auto-import", isOn: $monitorClipboard)
                .toggleStyle(.checkbox)
                .help("When enabled, copied direct links are added and started automatically")
        }
    }

    private var quickAddSection: some View {
        GroupBox("Link Grabber") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $linkGrabberInput)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 78, maxHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.7)
                    }

                HStack {
                    Button("Paste Links") {
                        linkGrabberInput = NSPasteboard.general.string(forType: .string) ?? ""
                        extractLinks()
                    }
                    Button("Extract") {
                        extractLinks()
                    }
                    Button("Add to Queue") {
                        queueGrabbedLinks(startImmediately: false)
                    }
                    .disabled(grabbedURLs.isEmpty)
                    Button("Start All") {
                        queueGrabbedLinks(startImmediately: true)
                    }
                    .disabled(grabbedURLs.isEmpty)

                    Spacer()

                    Text("\(grabbedURLs.count) link\(grabbedURLs.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !grabbedURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(grabbedURLs.prefix(5), id: \.absoluteString) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                Text(url.absoluteString)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        if grabbedURLs.count > 5 {
                            Text("…and \(grabbedURLs.count - 5) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var managerControls: some View {
        GroupBox("Direct Download") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("URL:")
                        .frame(width: 86, alignment: .leading)
                    TextField("https://example.com/file.zip", text: $downloadURL)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Save to:")
                        .frame(width: 86, alignment: .leading)
                    Text(selectedDestination.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose Folder…") { showFilePicker = true }
                }

                HStack {
                    Text("Queue:")
                        .frame(width: 86, alignment: .leading)

                    Stepper("\(downloadManager.maxSimultaneousDownloads) active", value: $downloadManager.maxSimultaneousDownloads, in: 1...12)
                        .frame(width: 160)

                    Toggle("Chunked", isOn: $downloadManager.multiConnectionEnabled)
                        .toggleStyle(.checkbox)

                    Stepper("\(downloadManager.connectionsPerDownload)x", value: $downloadManager.connectionsPerDownload, in: 1...16)
                        .frame(width: 110)
                        .disabled(!downloadManager.multiConnectionEnabled)

                    Spacer()
                }

                HStack {
                    Text("Global cap:")
                        .frame(width: 86, alignment: .leading)

                    Toggle("Unlimited", isOn: unlimitedBinding)
                        .toggleStyle(.checkbox)

                    Stepper(speedLimitDisplay, value: speedLimitBinding, in: (256 * 1024)...(100 * 1024 * 1024), step: 256 * 1024)
                        .frame(width: 190)
                        .disabled(downloadManager.speedLimitBytesPerSecond == 0)

                    Spacer()
                }

                HStack {
                    Button("Start Download") {
                        startDownload()
                    }
                    .disabled(!canStartDownload)

                    Button("Paste & Download") {
                        pasteAndStartImmediateDownload()
                    }

                    Spacer()

                    Text(canStartDownload ? "Ready" : "Enter valid URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var sourceLimitsSection: some View {
        GroupBox("Per-Source Limits") {
            if knownSources.isEmpty {
                Text("No source hosts yet. Start or queue a link to configure host-specific caps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(knownSources, id: \.self) { source in
                        HStack(spacing: 10) {
                            Text(source)
                                .font(.caption)
                                .frame(width: 150, alignment: .leading)

                            Toggle("Unlimited", isOn: sourceUnlimitedBinding(source))
                                .toggleStyle(.checkbox)

                            Stepper(
                                sourceLimitDisplay(for: source),
                                value: sourceSpeedBinding(source),
                                in: (128 * 1024)...(100 * 1024 * 1024),
                                step: 128 * 1024
                            )
                            .frame(width: 190)
                            .disabled(downloadManager.sourceSpeedLimit(for: source) == 0)

                            Stepper(
                                "Conn \(downloadManager.sourceConnectionLimit(for: source))",
                                value: sourceConnectionBinding(source),
                                in: 1...16
                            )
                            .frame(width: 110)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var queueList: some View {
        ForEach(queueTasks, id: \.id) { task in
            QueuedDownloadRow(download: task) {
                downloadManager.cancelDownload(taskId: task.id)
            }
        }

        ForEach(failedTasks, id: \.id) { task in
            FailedDownloadRow(download: task) {
                downloadManager.retryDownload(taskId: task.id)
            } onCancel: {
                downloadManager.cancelDownload(taskId: task.id)
            }
        }
    }

    @ViewBuilder
    private var runningList: some View {
        ForEach(runningTasks, id: \.id) { task in
            ActiveDownloadRow(download: task) {
                downloadManager.pauseDownload(taskId: task.id)
            } onCancel: {
                downloadManager.cancelDownload(taskId: task.id)
            }
        }
    }

    @ViewBuilder
    private var pausedList: some View {
        ForEach(downloadManager.pausedTasks) { record in
            PausedDownloadRow(record: record) {
                _ = downloadManager.resumeDownload(record: record)
            }
        }
    }

    @ViewBuilder
    private var completedList: some View {
        ForEach(downloadManager.completedTasks) { record in
            CompletedDownloadRow(record: record)
        }
    }

    private var speedLimitDisplay: String {
        guard downloadManager.speedLimitBytesPerSecond > 0 else { return "Unlimited" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: downloadManager.speedLimitBytesPerSecond))/s"
    }

    private func sourceLimitDisplay(for source: String) -> String {
        let current = downloadManager.sourceSpeedLimit(for: source)
        guard current > 0 else { return "Unlimited" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: current))/s"
    }

    private func sourceUnlimitedBinding(_ source: String) -> Binding<Bool> {
        Binding(
            get: { downloadManager.sourceSpeedLimit(for: source) == 0 },
            set: { unlimited in
                if unlimited {
                    downloadManager.setSourceSpeedLimit(for: source, bytesPerSecond: 0)
                } else if downloadManager.sourceSpeedLimit(for: source) == 0 {
                    downloadManager.setSourceSpeedLimit(for: source, bytesPerSecond: 1024 * 1024)
                }
            }
        )
    }

    private func sourceSpeedBinding(_ source: String) -> Binding<Int64> {
        Binding(
            get: { max(downloadManager.sourceSpeedLimit(for: source), 128 * 1024) },
            set: { newValue in
                downloadManager.setSourceSpeedLimit(
                    for: source,
                    bytesPerSecond: min(max(newValue, 128 * 1024), 100 * 1024 * 1024)
                )
            }
        )
    }

    private func sourceConnectionBinding(_ source: String) -> Binding<Int> {
        Binding(
            get: { min(max(downloadManager.sourceConnectionLimit(for: source), 1), 16) },
            set: { newValue in
                downloadManager.setSourceConnectionLimit(for: source, limit: min(max(newValue, 1), 16))
            }
        )
    }

    private func startDownload() {
        guard let sourceURL = resolvedDownloadURL(from: downloadURL) else {
            inputError = "Invalid URL"
            return
        }

        queueDownloads([sourceURL], startImmediately: true)
        inputError = nil
        downloadURL = ""
    }

    private func pasteAndStartImmediateDownload() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        guard let url = resolvedDownloadURL(from: pasted) else {
            inputError = "Clipboard does not contain valid URL"
            return
        }

        queueDownloads([url], startImmediately: true)
        inputError = nil
    }

    private func extractLinks() {
        grabbedURLs = extractLinks(from: linkGrabberInput)
    }

    private func queueGrabbedLinks(startImmediately: Bool) {
        guard !grabbedURLs.isEmpty else { return }
        queueDownloads(grabbedURLs, startImmediately: startImmediately)
        if startImmediately {
            activeTab = 1
        } else {
            activeTab = 0
        }
        grabbedURLs = []
        linkGrabberInput = ""
    }

    private func queueDownloads(_ urls: [URL], startImmediately: Bool) {
        guard !urls.isEmpty else { return }

        for url in urls {
            let destination = destinationURL(for: url)
            _ = downloadManager.startDownload(url: url, destination: destination)
        }

        if startImmediately {
            activeTab = 1
        }
    }

    private func extractLinks(from text: String) -> [URL] {
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

    private func handleClipboardImportTick() {
        guard monitorClipboard else { return }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = pasteboard.changeCount

        guard let raw = pasteboard.string(forType: .string),
              let url = resolvedDownloadURL(from: raw) else { return }

        if lastAutoImportedLink == url.absoluteString {
            return
        }

        lastAutoImportedLink = url.absoluteString
        queueDownloads([url], startImmediately: true)
        activeTab = 1
    }

    private func resolvedDownloadURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased(),
           ["http", "https", "ftp"].contains(scheme),
           parsed.host != nil {
            return parsed
        }

        if let inferred = URL(string: "https://\(trimmed)"),
           inferred.host != nil {
            return inferred
        }

        return nil
    }

    private func destinationURL(for sourceURL: URL) -> URL {
        let fileName = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
        let destination = selectedDestination.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            return destination
        }

        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(base) (\(counter))"
            } else {
                candidateName = "\(base) (\(counter)).\(ext)"
            }

            let candidate = selectedDestination.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }

            counter += 1
        }
    }
}

struct ActiveDownloadRow: View {
    let download: DownloadTask
    let onPause: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                Text(download.destination.lastPathComponent)
                    .lineLimit(1)
                Spacer()

                if download.status == .repairing {
                    Image(systemName: "wrench.fill")
                        .foregroundColor(.orange)
                }
            }

            ProgressView(value: download.progress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: download.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if download.currentSpeedBytesPerSecond > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(download.currentSpeedBytesPerSecond), countStyle: .file))/s")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let eta = download.etaSeconds {
                    Text("ETA \(formatETA(eta))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(download.status.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Pause") {
                    onPause()
                }
                .buttonStyle(.borderless)

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }
}

struct QueuedDownloadRow: View {
    let download: DownloadTask
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "list.bullet")
                .foregroundColor(.secondary)
            VStack(alignment: .leading) {
                Text(download.destination.lastPathComponent)
                    .lineLimit(1)
                Text(download.packageName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("Queued")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Remove") { onCancel() }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct FailedDownloadRow: View {
    let download: DownloadTask
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading) {
                Text(download.destination.lastPathComponent)
                    .lineLimit(1)
                Text(download.error ?? "Failed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") { onRetry() }
                .buttonStyle(.bordered)
            Button("Dismiss") { onCancel() }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct PausedDownloadRow: View {
    let record: DownloadManager.DownloadRecord
    let onResume: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "pause.circle.fill")
                .foregroundColor(.orange)

            VStack(alignment: .leading) {
                Text(record.fileName)
                    .lineLimit(1)
                Text("\(Int(record.progress * 100))% complete")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Resume") {
                onResume()
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct CompletedDownloadRow: View {
    let record: DownloadManager.DownloadRecord

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)

            VStack(alignment: .leading) {
                Text(record.fileName)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Open") {
                NSWorkspace.shared.open(record.destination)
            }
            .buttonStyle(.bordered)

            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(record.destination.path, inFileViewerRootedAtPath: "")
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct RepairDownloadSheet: View {
    let download: DownloadTask
    let onRepair: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Repair Download")
                .font(.headline)

            Text("This will attempt to repair partially downloaded file by requesting only missing bytes from server.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack {
                Text("Progress:")
                    .foregroundColor(.secondary)
                Text("\(Int(download.progress * 100))%")
            }

            HStack {
                Text("Downloaded:")
                    .foregroundColor(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: download.downloadedBytes, countStyle: .file))
            }

            HStack {
                Text("Total:")
                    .foregroundColor(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Repair") {
                    onRepair()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
