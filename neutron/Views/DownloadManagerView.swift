import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Combine

struct DownloadManagerPanelView: View {
    private enum DownloadTab: Int {
        case queue = 0
        case running = 1
        case paused = 2
        case completed = 3
    }

    @StateObject private var downloadManager = DownloadManager.shared

    @AppStorage("downloadDefaultPath") private var downloadDefaultPath: String = ""

    @State private var showFilePicker = false
    @State private var downloadURL = ""
    @State private var selectedDestination: URL = {
        if let saved = UserDefaults.standard.string(forKey: "downloadDefaultPath"), !saved.isEmpty {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }()
    @State private var activeTab: DownloadTab = .queue
    @State private var inputError: String?

    @State private var linkGrabberInput = ""
    @State private var grabbedURLs: [URL] = []
    @State private var monitorClipboard = true
    @State private var clipboardChangeCount = NSPasteboard.general.changeCount
    @State private var lastAutoImportedLink: String?

    @State private var searchText = ""
    @State private var newTaskPriority: DownloadPriority = .normal
    @State private var newTaskNote = ""
    @State private var applyCustomSchedule = false
    @State private var customScheduledDate = Date().addingTimeInterval(3600)

    private let clipboardTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    private var queueTasks: [DownloadTask] { filterTasks(downloadManager.queuedTasks) }
    private var runningTasks: [DownloadTask] { filterTasks(downloadManager.runningTasks) }
    private var failedTasks: [DownloadTask] { filterTasks(downloadManager.failedTasks) }
    private var pausedTasks: [DownloadManager.DownloadRecord] { filterRecords(downloadManager.pausedTasks) }
    private var completedTasks: [DownloadManager.DownloadRecord] { filterRecords(downloadManager.completedTasks) }

    private var knownSources: [String] { downloadManager.knownSources() }

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

    private var pauseModeSpeedLimitBinding: Binding<Int64> {
        Binding(
            get: { max(downloadManager.pauseModeSpeedLimitBytesPerSecond, 64 * 1024) },
            set: { newValue in
                downloadManager.pauseModeSpeedLimitBytesPerSecond = min(max(newValue, 64 * 1024), 50 * 1024 * 1024)
            }
        )
    }

    private var canStartDownload: Bool {
        resolvedDownloadURL(from: downloadURL) != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Form {
                Section("Quick Add") {
                    Toggle("Clipboard auto-import", isOn: $monitorClipboard)

                    TextEditor(text: $linkGrabberInput)
                        .frame(minHeight: 70, maxHeight: 110)

                    HStack {
                        Button("Paste") {
                            linkGrabberInput = NSPasteboard.general.string(forType: .string) ?? ""
                            extractLinks()
                        }
                        Button("Extract") { extractLinks() }
                        Button("Queue") { queueGrabbedLinks(startImmediately: false) }
                            .disabled(grabbedURLs.isEmpty)
                        Button("Start") { queueGrabbedLinks(startImmediately: true) }
                            .disabled(grabbedURLs.isEmpty)
                    }

                    Text("Detected: \(grabbedURLs.count)")
                        .foregroundStyle(.secondary)
                }

                Section("New Download") {
                    TextField("https://example.com/file.zip", text: $downloadURL)
                    Text(selectedDestination.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose Destination Folder…") { showFilePicker = true }

                    Picker("Priority", selection: $newTaskPriority) {
                        ForEach(DownloadPriority.allCases) { priority in
                            Text(priority.title).tag(priority)
                        }
                    }

                    TextField("Note (optional)", text: $newTaskNote)

                    Toggle("Use custom start date", isOn: $applyCustomSchedule)
                    if applyCustomSchedule {
                        DatePicker("Start at", selection: $customScheduledDate)
                    }

                    HStack {
                        Button("Start Download") { startDownload() }
                            .disabled(!canStartDownload)
                        Button("Paste & Start") { pasteAndStartImmediateDownload() }
                    }

                    if let inputError {
                        Text(inputError)
                            .foregroundStyle(.red)
                    }
                }

                Section("Queue & Limits") {
                    Stepper("Active downloads: \(downloadManager.maxSimultaneousDownloads)", value: $downloadManager.maxSimultaneousDownloads, in: 1...12)
                    Toggle("Chunked downloads", isOn: $downloadManager.multiConnectionEnabled)
                    Stepper("Connections per download: \(downloadManager.connectionsPerDownload)", value: $downloadManager.connectionsPerDownload, in: 1...16)
                        .disabled(!downloadManager.multiConnectionEnabled)

                    Toggle("Unlimited global speed", isOn: unlimitedBinding)
                    Stepper(speedLimitDisplay, value: speedLimitBinding, in: (256 * 1024)...(100 * 1024 * 1024), step: 256 * 1024)
                        .disabled(downloadManager.speedLimitBytesPerSecond == 0)

                    Toggle("Pause mode", isOn: $downloadManager.pauseModeEnabled)
                    Stepper(pauseModeSpeedLimitDisplay, value: pauseModeSpeedLimitBinding, in: (64 * 1024)...(50 * 1024 * 1024), step: 64 * 1024)

                    Toggle("Auto extract ZIP", isOn: $downloadManager.autoExtractArchives)
                    Toggle("Prevent duplicate URLs", isOn: $downloadManager.preventDuplicateURLs)

                    Stepper("Default retries: \(downloadManager.defaultMaxRetries)", value: $downloadManager.defaultMaxRetries, in: 1...20)
                    Stepper("Default start delay (min): \(downloadManager.defaultScheduleDelayMinutes)", value: $downloadManager.defaultScheduleDelayMinutes, in: 0...720)
                    Stepper("Auto-clean done after days: \(downloadManager.autoCleanupCompletedDays)", value: $downloadManager.autoCleanupCompletedDays, in: 0...90)

                    TextField("Filename prefix template", text: $downloadManager.filenamePrefixTemplate)
                    TextField("Filename suffix template", text: $downloadManager.filenameSuffixTemplate)
                }

                Section("Bulk Actions") {
                    Button("Pause All") { downloadManager.pauseAllDownloads() }
                    Button("Resume All Paused") { downloadManager.resumeAllDownloads() }
                    Button("Clear Completed") { downloadManager.clearCompletedTasks() }
                }

                if !knownSources.isEmpty {
                    Section("Per-Source Limits") {
                        ForEach(knownSources, id: \.self) { source in
                            VStack(alignment: .leading) {
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Toggle("Unlimited", isOn: sourceUnlimitedBinding(source))
                                    Stepper(
                                        sourceLimitDisplay(for: source),
                                        value: sourceSpeedBinding(source),
                                        in: (128 * 1024)...(100 * 1024 * 1024),
                                        step: 128 * 1024
                                    )
                                    .disabled(downloadManager.sourceSpeedLimit(for: source) == 0)
                                }

                                Stepper(
                                    "Connections: \(downloadManager.sourceConnectionLimit(for: source))",
                                    value: sourceConnectionBinding(source),
                                    in: 1...16
                                )
                            }
                        }
                    }
                }
            }
            .frame(width: 360)

            VStack(alignment: .leading, spacing: 8) {
                Picker("View", selection: $activeTab) {
                    Text("Queue \(queueTasks.count + failedTasks.count)").tag(DownloadTab.queue)
                    Text("Running \(runningTasks.count)").tag(DownloadTab.running)
                    Text("Paused \(pausedTasks.count)").tag(DownloadTab.paused)
                    Text("Done \(completedTasks.count)").tag(DownloadTab.completed)
                }
                .pickerStyle(.segmented)

                List {
                    switch activeTab {
                    case .queue:
                        if !queueTasks.isEmpty {
                            Section("Queued") {
                                ForEach(queueTasks, id: \.id) { task in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(task.destination.lastPathComponent)
                                            Spacer()
                                            Picker("Priority", selection: priorityBinding(for: task)) {
                                                ForEach(DownloadPriority.allCases) { priority in
                                                    Text(priority.title).tag(priority)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 95)

                                            Button {
                                                downloadManager.moveQueuedTask(taskId: task.id, action: .up)
                                            } label: { Image(systemName: "arrow.up") }

                                            Button {
                                                downloadManager.moveQueuedTask(taskId: task.id, action: .down)
                                            } label: { Image(systemName: "arrow.down") }

                                            Button("Pause") { downloadManager.pauseDownload(taskId: task.id) }
                                            Button("Remove") { downloadManager.cancelDownload(taskId: task.id) }
                                        }

                                        HStack {
                                            Text(task.packageName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let scheduledAt = task.scheduledAt {
                                                Text("Scheduled: \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        if !task.note.isEmpty {
                                            Text(task.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        if !failedTasks.isEmpty {
                            Section("Failed") {
                                ForEach(failedTasks, id: \.id) { task in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(task.destination.lastPathComponent)
                                            Text(task.error ?? "Failed")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Retry") { downloadManager.retryDownload(taskId: task.id) }
                                        Button("Dismiss") { downloadManager.cancelDownload(taskId: task.id) }
                                    }
                                }
                            }
                        }

                    case .running:
                        Section("Running") {
                            ForEach(runningTasks, id: \.id) { task in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(task.destination.lastPathComponent)
                                        Spacer()
                                        Text(task.priority.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Button("Pause") { downloadManager.pauseDownload(taskId: task.id) }
                                        Button("Cancel") { downloadManager.cancelDownload(taskId: task.id) }
                                    }

                                    ProgressView(value: task.progress)

                                    HStack {
                                        Text("\(ByteCountFormatter.string(fromByteCount: task.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if task.currentSpeedBytesPerSecond > 0 {
                                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(task.currentSpeedBytesPerSecond), countStyle: .binary))/s")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if !task.note.isEmpty {
                                        Text(task.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                    case .paused:
                        Section("Paused") {
                            ForEach(pausedTasks, id: \.id) { record in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(record.fileName)
                                        Text("\(Int(record.progress * 100))% • \(record.priority.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if !record.note.isEmpty {
                                            Text(record.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Resume") { _ = downloadManager.resumeDownload(record: record) }
                                }
                            }
                        }

                    case .completed:
                        Section("Completed") {
                            ForEach(completedTasks, id: \.id) { record in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(record.fileName)
                                        Text(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(record.priority.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if !record.note.isEmpty {
                                            Text(record.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if !record.extractedPaths.isEmpty {
                                            Text("Extracted")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Open") { NSWorkspace.shared.open(record.destination) }
                                    Button("Show") {
                                        NSWorkspace.shared.selectFile(record.destination.path, inFileViewerRootedAtPath: "")
                                    }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $searchText, placement: .automatic, prompt: "Search downloads")
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(minWidth: 980, minHeight: 640)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedDestination = url
                downloadDefaultPath = url.path
            }
        }
        .onReceive(clipboardTimer) { _ in
            handleClipboardImportTick()
        }
        .onAppear {
            if !FileManager.default.fileExists(atPath: selectedDestination.path) {
                let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                selectedDestination = fallback
                downloadDefaultPath = fallback.path
            }
        }
    }

    private func speedText(_ value: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: value, countStyle: .binary))/s"
    }

    private var speedLimitDisplay: String {
        guard downloadManager.speedLimitBytesPerSecond > 0 else { return "Unlimited" }
        return speedText(downloadManager.speedLimitBytesPerSecond)
    }

    private var pauseModeSpeedLimitDisplay: String {
        speedText(downloadManager.pauseModeSpeedLimitBytesPerSecond)
    }

    private func priorityBinding(for task: DownloadTask) -> Binding<DownloadPriority> {
        Binding(
            get: { task.priority },
            set: { downloadManager.setPriority(taskId: task.id, priority: $0) }
        )
    }

    private func sourceLimitDisplay(for source: String) -> String {
        let current = downloadManager.sourceSpeedLimit(for: source)
        guard current > 0 else { return "Unlimited" }
        return speedText(current)
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
            inputError = "Clipboard has no valid URL"
            return
        }

        queueDownloads([url], startImmediately: true)
        inputError = nil
    }

    private func extractLinks() {
        grabbedURLs = DownloadLinkGrabber.extractLinks(from: linkGrabberInput)
    }

    private func queueGrabbedLinks(startImmediately: Bool) {
        guard !grabbedURLs.isEmpty else { return }
        queueDownloads(grabbedURLs, startImmediately: startImmediately)
        activeTab = startImmediately ? .running : .queue
        grabbedURLs = []
        linkGrabberInput = ""
    }

    private func queueDownloads(_ urls: [URL], startImmediately: Bool) {
        guard !urls.isEmpty else { return }

        let tasks = downloadManager.startDownloads(urls: urls, destinationDirectory: selectedDestination, startImmediately: startImmediately)
        for task in tasks {
            downloadManager.setPriority(taskId: task.id, priority: newTaskPriority)
            downloadManager.setNote(taskId: task.id, note: newTaskNote)
            if applyCustomSchedule {
                downloadManager.setScheduledStart(taskId: task.id, date: customScheduledDate)
            }
        }

        if startImmediately {
            activeTab = .running
        }
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
    }

    private func resolvedDownloadURL(from input: String) -> URL? {
        DownloadLinkGrabber.resolvedDownloadURL(from: input)
    }

    private func filterTasks(_ tasks: [DownloadTask]) -> [DownloadTask] {
        tasks.filter { task in
            DownloadSearchMatcher.matches(
                query: searchText,
                values: [
                    task.destination.lastPathComponent,
                    task.url.absoluteString,
                    task.packageName,
                    task.note
                ]
            )
        }
    }

    private func filterRecords(_ records: [DownloadManager.DownloadRecord]) -> [DownloadManager.DownloadRecord] {
        records.filter { record in
            DownloadSearchMatcher.matches(
                query: searchText,
                values: [
                    record.fileName,
                    record.url.absoluteString,
                    record.packageName ?? "",
                    record.note
                ]
            )
        }
    }
}
