//
//  CLITools.swift
//  neutron
//
//  CLI tools integration for ffmpeg and yt-dlp
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - CLI Tool Protocol

protocol CLITool {
    var name: String { get }
    var executable: String { get }
    var isAvailable: Bool { get }
    func install() async throws
}

// MARK: - Tool Status

enum ToolStatus: Equatable {
    case unknown
    case notInstalled
    case installed(version: String)
    case running
    case error(String)
}

// MARK: - CLI Tool Manager

class CLIToolManager: ObservableObject {
    static let shared = CLIToolManager()

    @Published var ffmpegStatus: ToolStatus = .unknown
    @Published var ytdlpStatus: ToolStatus = .unknown
    @Published var activeDownloads: [CLIDownloadTask] = []
    @Published var activeConversions: [ConversionTask] = []
    @Published var activeTorrentTasks: [TorrentTask] = []

    private var torrentEngines: [UUID: BitTorrentEngine] = [:]
    private var engineTaskIDs: [ObjectIdentifier: UUID] = [:]

    init() {
        checkToolsAvailability()
    }

    func checkToolsAvailability() {
        Task { @MainActor in
            ffmpegStatus = await checkTool("ffmpeg")
            ytdlpStatus = await checkTool("yt-dlp")
        }
    }

    private func checkTool(_ name: String) async -> ToolStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Tool exists, get version
                return await getToolVersion(name)
            } else {
                return .notInstalled
            }
        } catch {
            return .notInstalled
        }
    }

    private func getToolVersion(_ name: String) async -> ToolStatus {
        let process = Process()
        let paths = ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/bin/\(name)"]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["--version"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        let version = output.components(separatedBy: "\n").first ?? "unknown"
                        return .installed(version: version.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    continue
                }
            }
        }
        return .notInstalled
    }

    // MARK: - ffmpeg Operations

    func convertMedia(
        input: URL,
        output: URL,
        options: FFmpegOptions,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard case .installed = ffmpegStatus else {
            throw CLIToolError.notInstalled("ffmpeg")
        }

        let task = ConversionTask(input: input, output: output, progress: 0)
        await MainActor.run {
            activeConversions.append(task)
        }

        defer {
            Task { @MainActor in
                activeConversions.removeAll { $0.id == task.id }
            }
        }

        let ffmpegPath = findExecutable("ffmpeg") ?? "/usr/local/bin/ffmpeg"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        var args = ["-i", input.path]
        args.append(contentsOf: options.arguments)
        args.append("-y") // Overwrite output
        args.append(output.path)

        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()

        // Parse progress from stderr
        Task {
            let handle = stderrPipe.fileHandleForReading
            while process.isRunning {
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8) {
                    if let progressValue = parseFFmpegProgress(output) {
                        await MainActor.run {
                            progress(progressValue)
                        }
                    }
                }
            }
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw CLIToolError.executionFailed("ffmpeg exited with code \(process.terminationStatus)")
        }
    }

    private func parseFFmpegProgress(_ output: String) -> Double? {
        // Look for "time=00:00:00.00" pattern
        guard output.range(of: "time=\\d+:\\d+:\\d+\\.\\d+", options: .regularExpression) != nil else {
            return nil
        }
        // This is a simplified progress - in production you'd compare to total duration
        return nil
    }

    // MARK: - yt-dlp Operations

    func downloadVideo(
        url: String,
        destination: URL,
        options: YTDLPOptions,
        progress: @escaping (DownloadProgress) -> Void
    ) async throws {
        guard case .installed = ytdlpStatus else {
            throw CLIToolError.notInstalled("yt-dlp")
        }

        let task = CLIDownloadTask(url: url, destination: destination, progress: 0, status: "Starting...")
        await MainActor.run {
            activeDownloads.append(task)
        }

        defer {
            Task { @MainActor in
                activeDownloads.removeAll { $0.id == task.id }
            }
        }

        let ytdlpPath = findExecutable("yt-dlp") ?? "/usr/local/bin/yt-dlp"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlpPath)

        var args = [url, "-o", destination.path]
        args.append(contentsOf: options.arguments)
        args.append("--newline") // Each progress on new line
        args.append("--progress-template")
        args.append("%(progress._percent_str)s")

        process.arguments = args

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()

        // Parse progress from stdout
        Task {
            let handle = stdoutPipe.fileHandleForReading
            while process.isRunning {
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8) {
                    if let progressValue = parseYTDLPProgress(output) {
                        await MainActor.run {
                            progress(progressValue)
                        }
                    }
                }
            }
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw CLIToolError.executionFailed("yt-dlp exited with code \(process.terminationStatus)")
        }
    }

    private func parseYTDLPProgress(_ output: String) -> DownloadProgress? {
        // Parse percentage like "45.2%"
        if let range = output.range(of: "\\d+\\.?\\d*%", options: .regularExpression) {
            let percentStr = String(output[range]).replacingOccurrences(of: "%", with: "")
            if let percent = Double(percentStr) {
                return DownloadProgress(percent: percent / 100, status: "Downloading...")
            }
        }
        return nil
    }

    func startTorrent(
        source: TorrentSource,
        destination: URL
    ) async throws {
        let task = TorrentTask(
            source: source,
            destination: destination,
            progress: 0,
            status: "Preparing native torrent session..."
        )

        await MainActor.run {
            activeTorrentTasks.append(task)
        }

        do {
            switch source {
            case .magnet(let magnetLink):
                let magnet = try MagnetLink(urlString: magnetLink)
                let peerId = BitTorrentPeerID.generate()
                let resolver = MagnetMetadataResolver(magnet: magnet, peerId: peerId) { [weak self] progress, status in
                    Task { @MainActor in
                        self?.updateTorrentTask(id: task.id, progress: progress, status: status)
                    }
                }
                let resolvedMagnet = try await resolver.resolve()

                let engine = BitTorrentEngine(
                    torrent: resolvedMagnet.torrent,
                    outputDirectory: destination,
                    peerId: resolvedMagnet.peerId
                )
                engine.delegate = self

                await MainActor.run {
                    torrentEngines[task.id] = engine
                    engineTaskIDs[ObjectIdentifier(engine)] = task.id
                    updateTorrentTask(id: task.id, progress: 0.08, status: "Connecting to peers...")
                }

                engine.start(initialPeers: resolvedMagnet.initialPeers)
            case .file(let url):
                let data = try Data(contentsOf: url)
                guard let torrent = TorrentFile(data: data) else {
                    throw BitTorrentError.invalidTorrent
                }

                let engine = BitTorrentEngine(torrent: torrent, outputDirectory: destination)
                engine.delegate = self

                await MainActor.run {
                    torrentEngines[task.id] = engine
                    engineTaskIDs[ObjectIdentifier(engine)] = task.id
                    updateTorrentTask(id: task.id, progress: 0.02, status: "Connecting to tracker...")
                }

                engine.start()
            }
            await MainActor.run {
                if case .magnet = source {
                    updateTorrentTask(id: task.id, progress: 0.08, status: "Waiting for peer connections...")
                }
            }
        } catch {
            await MainActor.run {
                self.updateTorrentTask(
                    id: task.id,
                    progress: self.torrentTask(id: task.id)?.progress ?? 0,
                    status: error.localizedDescription
                )
            }
            throw error
        }
    }

    func stopTorrent(taskID: UUID) {
        if let engine = torrentEngines[taskID] {
            engine.cancel()
            engineTaskIDs.removeValue(forKey: ObjectIdentifier(engine))
        }
        torrentEngines.removeValue(forKey: taskID)
        updateTorrentTask(id: taskID, progress: torrentTask(id: taskID)?.progress ?? 0, status: "Stopped")
    }

    func removeTorrentTask(taskID: UUID) {
        stopTorrent(taskID: taskID)
        activeTorrentTasks.removeAll { $0.id == taskID }
    }

    private func torrentTask(id: UUID) -> TorrentTask? {
        activeTorrentTasks.first(where: { $0.id == id })
    }

    private func updateTorrentTask(id: UUID, progress: Double, status: String) {
        guard let index = activeTorrentTasks.firstIndex(where: { $0.id == id }) else { return }
        activeTorrentTasks[index].progress = min(max(progress, 0), 1)
        activeTorrentTasks[index].status = status
    }

    private func findExecutable(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Supporting Types

struct FFmpegOptions {
    var format: String?
    var videoCodec: String?
    var audioCodec: String?
    var bitrate: String?
    var resolution: String?
    var customArgs: [String]

    static let `default` = FFmpegOptions(customArgs: [])

    var arguments: [String] {
        var args: [String] = []
        if let format = format { args.append(contentsOf: ["-f", format]) }
        if let vc = videoCodec { args.append(contentsOf: ["-c:v", vc]) }
        if let ac = audioCodec { args.append(contentsOf: ["-c:a", ac]) }
        if let bitrate = bitrate { args.append(contentsOf: ["-b:v", bitrate]) }
        if let res = resolution { args.append(contentsOf: ["-s", res]) }
        args.append(contentsOf: customArgs)
        return args
    }
}

struct YTDLPOptions {
    var format: String?
    var extractAudio: Bool
    var audioFormat: String?
    var subtitles: Bool
    var customArgs: [String]

    static let `default` = YTDLPOptions(extractAudio: false, subtitles: false, customArgs: [])

    var arguments: [String] {
        var args: [String] = []
        if let format = format { args.append(contentsOf: ["-f", format]) }
        if extractAudio {
            args.append("-x")
            if let audioFormat = audioFormat {
                args.append(contentsOf: ["--audio-format", audioFormat])
            }
        }
        if subtitles { args.append("--write-subs") }
        args.append(contentsOf: customArgs)
        return args
    }
}

struct DownloadProgress {
    let percent: Double
    let status: String
}

enum TorrentSource {
    case magnet(String)
    case file(URL)

    var displayName: String {
        switch self {
        case .magnet(let magnet):
            if let nameRange = magnet.range(of: "dn=", options: .caseInsensitive) {
                let suffix = magnet[nameRange.upperBound...]
                let rawName = suffix.split(separator: "&").first.map(String.init) ?? "Magnet Link"
                return rawName.removingPercentEncoding ?? rawName
            }
            return "Magnet Link"
        case .file(let url):
            return url.lastPathComponent
        }
    }

    var sourceDescription: String {
        switch self {
        case .magnet(let magnet):
            return magnet
        case .file(let url):
            return url.path
        }
    }
}

struct CLIDownloadTask: Identifiable {
    let id = UUID()
    let url: String
    let destination: URL
    var progress: Double
    var status: String
}

struct TorrentTask: Identifiable {
    let id = UUID()
    let source: TorrentSource
    let destination: URL
    var progress: Double
    var status: String

    var isFinished: Bool {
        progress >= 1.0 || status == "Stopped"
    }
}

struct ConversionTask: Identifiable {
    let id = UUID()
    let input: URL
    let output: URL
    var progress: Double
}

enum CLIToolError: LocalizedError {
    case notInstalled(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool):
            return "\(tool) is not installed. Install it via Homebrew: brew install \(tool)"
        case .executionFailed(let msg):
            return msg
        }
    }
}

// MARK: - CLI Tools Panel View

struct CLIToolsPanelView: View {
    @StateObject private var manager = CLIToolManager.shared
    @State private var downloadURL = ""
    @State private var torrentMagnetLink = ""
    @State private var selectedDestination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @State private var showFilePicker = false
    @State private var showTorrentFilePicker = false
    @State private var selectedTorrentFile: URL?
    @State private var downloadProgress: Double = 0
    @State private var torrentProgress: Double = 0
    @State private var isDownloading = false
    @State private var isStartingTorrent = false
    @State private var errorMessage: String?
    @State private var pendingPanelAction: DownloadsPanelAction?

    private enum DownloadsPanelAction {
        case videoDownload
        case torrentMagnet
        case torrentFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Tool Status
            GroupBox("Installed Tools") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: toolStatusIcon(manager.ffmpegStatus))
                            .foregroundColor(toolStatusColor(manager.ffmpegStatus))
                        Text("ffmpeg")
                        Spacer()
                        Text(toolStatusText(manager.ffmpegStatus))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Image(systemName: toolStatusIcon(manager.ytdlpStatus))
                            .foregroundColor(toolStatusColor(manager.ytdlpStatus))
                        Text("yt-dlp")
                        Spacer()
                        Text(toolStatusText(manager.ytdlpStatus))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    Button("Refresh") {
                        manager.checkToolsAvailability()
                    }
                    .buttonStyle(.link)
                }
                .padding(.vertical, 4)
            }

            // Download Section
            if case .installed = manager.ytdlpStatus {
                GroupBox("Download Video") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Video URL (YouTube, etc.)", text: $downloadURL)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Text("Destination: \(selectedDestination.lastPathComponent)")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Choose...") {
                                showFilePicker = true
                            }
                        }

                        if isDownloading {
                            ProgressView(value: downloadProgress)
                            Text("Downloading: \(Int(downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Button("Download") {
                                startDownload()
                            }
                            .disabled(downloadURL.isEmpty || isDownloading)

                            Button("Download Audio Only") {
                                startDownload(audioOnly: true)
                            }
                            .disabled(downloadURL.isEmpty || isDownloading)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            GroupBox("Torrent") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Magnet link", text: $torrentMagnetLink)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Choose .torrent…") {
                            showTorrentFilePicker = true
                        }

                        if let selectedTorrentFile {
                            Text(selectedTorrentFile.lastPathComponent)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("No torrent file selected")
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    HStack {
                        Text("Destination: \(selectedDestination.lastPathComponent)")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Choose Folder...") {
                            showFilePicker = true
                        }
                    }

                    if isStartingTorrent {
                        ProgressView(value: torrentProgress)
                        Text("Preparing torrent workflow: \(Int(torrentProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Button("Add Magnet") {
                            startTorrentFromMagnet()
                        }
                        .disabled(torrentMagnetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStartingTorrent)

                        Button("Add Torrent File") {
                            startTorrentFromSelectedFile()
                        }
                        .disabled(selectedTorrentFile == nil || isStartingTorrent)
                    }

                    Text("Torrent files and magnet links now run through Neutron's native BitTorrent engine, including native metadata fetch and DHT peer discovery.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // Active Tasks
            if !manager.activeDownloads.isEmpty || !manager.activeConversions.isEmpty || !manager.activeTorrentTasks.isEmpty {
                GroupBox("Active Tasks") {
                    VStack(alignment: .leading) {
                        ForEach(manager.activeDownloads) { task in
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text(task.url.prefix(40) + "...")
                                Spacer()
                                ProgressView(value: task.progress)
                                    .frame(width: 100)
                            }
                        }
                        ForEach(manager.activeTorrentTasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(task.source.displayName)
                                            .lineLimit(1)
                                        Text(task.status)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    ProgressView(value: task.progress)
                                        .frame(width: 100)
                                }

                                HStack {
                                    Spacer()
                                    if task.isFinished {
                                        Button("Remove") {
                                            manager.removeTorrentTask(taskID: task.id)
                                        }
                                        .buttonStyle(.borderless)
                                    } else {
                                        Button("Stop") {
                                            manager.stopTorrent(taskID: task.id)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        ForEach(manager.activeConversions) { task in
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text(task.input.lastPathComponent)
                                Spacer()
                                ProgressView(value: task.progress)
                                    .frame(width: 100)
                            }
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 300, minHeight: 200)
        .onReceive(NotificationCenter.default.publisher(for: .showVideoDownload)) { _ in
            pendingPanelAction = .videoDownload
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTorrentMagnet)) { _ in
            pendingPanelAction = .torrentMagnet
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTorrentFilePicker)) { _ in
            pendingPanelAction = .torrentFile
        }
        .onChange(of: pendingPanelAction) { _, action in
            guard let action else { return }
            handlePanelAction(action)
            pendingPanelAction = nil
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedDestination = url
            }
        }
        .fileImporter(
            isPresented: $showTorrentFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedTorrentFile = url
            }
        }
    }

    private func startDownload(audioOnly: Bool = false) {
        guard !downloadURL.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let filename = "%(title)s.%(ext)s"
        let outputPath = selectedDestination.appendingPathComponent(filename)

        var options = YTDLPOptions.default
        if audioOnly {
            options.extractAudio = true
            options.audioFormat = "mp3"
        }

        Task {
            do {
                try await manager.downloadVideo(
                    url: downloadURL,
                    destination: outputPath,
                    options: options
                ) { progress in
                    downloadProgress = progress.percent
                }

                await MainActor.run {
                    isDownloading = false
                    downloadURL = ""
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startTorrentFromMagnet() {
        let magnet = torrentMagnetLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !magnet.isEmpty else { return }

        isStartingTorrent = true
        torrentProgress = 0.15
        errorMessage = nil

        Task {
            do {
                try await manager.startTorrent(
                    source: .magnet(magnet),
                    destination: selectedDestination
                )
                await MainActor.run {
                    torrentProgress = 1.0
                    isStartingTorrent = false
                    torrentMagnetLink = ""
                }
            } catch {
                await MainActor.run {
                    isStartingTorrent = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startTorrentFromSelectedFile() {
        guard let fileURL = selectedTorrentFile else { return }

        isStartingTorrent = true
        torrentProgress = 0.15
        errorMessage = nil

        Task {
            do {
                try await manager.startTorrent(
                    source: .file(fileURL),
                    destination: selectedDestination
                )
                await MainActor.run {
                    torrentProgress = 1.0
                    isStartingTorrent = false
                    selectedTorrentFile = nil
                }
            } catch {
                await MainActor.run {
                    isStartingTorrent = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handlePanelAction(_ action: DownloadsPanelAction) {
        switch action {
        case .videoDownload:
            if downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                downloadURL = "https://"
            }
        case .torrentMagnet:
            if torrentMagnetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                torrentMagnetLink = "magnet:?"
            }
        case .torrentFile:
            showTorrentFilePicker = true
        }
    }

    private func toolStatusIcon(_ status: ToolStatus) -> String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .notInstalled: return "xmark.circle"
        case .running: return "hourglass"
        case .unknown: return "questionmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func toolStatusColor(_ status: ToolStatus) -> Color {
        switch status {
        case .installed: return .green
        case .notInstalled: return .red
        case .running: return .orange
        case .unknown: return .secondary
        case .error: return .red
        }
    }

    private func toolStatusText(_ status: ToolStatus) -> String {
        switch status {
        case .installed(let version): return version
        case .notInstalled: return "Not installed"
        case .running: return "Running..."
        case .unknown: return "Checking..."
        case .error(let msg): return msg
        }
    }
}

extension CLIToolManager: BitTorrentEngineDelegate {
    func engine(_ engine: BitTorrentEngine, didUpdateProgress progress: Double, downloaded: Int64, total: Int64) {
        DispatchQueue.main.async {
            guard let taskID = self.engineTaskIDs[ObjectIdentifier(engine)] else { return }
            let downloadedString = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
            let totalString = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let currentProgress = self.torrentTask(id: taskID)?.progress ?? 0
            self.updateTorrentTask(id: taskID, progress: max(progress, currentProgress), status: "Downloading \(downloadedString) of \(totalString)")
        }
    }

    func engine(_ engine: BitTorrentEngine, didCompletePiece index: Int) {
        DispatchQueue.main.async {
            guard let taskID = self.engineTaskIDs[ObjectIdentifier(engine)] else { return }
            let progress = self.torrentTask(id: taskID)?.progress ?? 0
            self.updateTorrentTask(id: taskID, progress: progress, status: "Verified piece \(index + 1) of \(engine.getDownloadedPieces().count)")
        }
    }

    func engine(_ engine: BitTorrentEngine, didFinishDownloading files: [URL]) {
        DispatchQueue.main.async {
            guard let taskID = self.engineTaskIDs[ObjectIdentifier(engine)] else { return }
            self.updateTorrentTask(id: taskID, progress: 1.0, status: "Completed")
            self.torrentEngines.removeValue(forKey: taskID)
            self.engineTaskIDs.removeValue(forKey: ObjectIdentifier(engine))
        }
    }

    func engine(_ engine: BitTorrentEngine, didEncounterError error: Error) {
        DispatchQueue.main.async {
            guard let taskID = self.engineTaskIDs[ObjectIdentifier(engine)] else { return }
            self.updateTorrentTask(id: taskID, progress: self.torrentTask(id: taskID)?.progress ?? 0, status: error.localizedDescription)
        }
    }

    func engine(_ engine: BitTorrentEngine, didUpdatePeers peers: [PeerInfo]) {
        DispatchQueue.main.async {
            guard let taskID = self.engineTaskIDs[ObjectIdentifier(engine)] else { return }
            let progress = self.torrentTask(id: taskID)?.progress ?? 0.02
            self.updateTorrentTask(id: taskID, progress: progress, status: "Found \(peers.count) tracker peers")
        }
    }

    func engine(_ engine: BitTorrentEngine, didUpdateStats stats: TorrentStats) {
        DispatchQueue.main.async {
            guard let taskID = self.engineTaskIDs[ObjectIdentifier(engine)] else { return }
            let speed = stats.downloadSpeed > 0 ? ByteCountFormatter.string(fromByteCount: Int64(stats.downloadSpeed), countStyle: .file) + "/s" : nil
            let peers = max(stats.peersConnected, 0)
            let status = speed.map { "Downloading from \(peers) peers • \($0)" } ?? "Connecting to \(peers) peers"
            self.updateTorrentTask(id: taskID, progress: self.torrentTask(id: taskID)?.progress ?? 0.02, status: status)
        }
    }
}

// MARK: - Context Menu Integration

extension View {
    func cliToolsContextMenu(for file: URL) -> some View {
        self.contextMenu {
            if case .installed = CLIToolManager.shared.ffmpegStatus {
                Menu("Convert with ffmpeg") {
                    Button("To MP4") {
                        convertFile(file, to: "mp4")
                    }
                    Button("To MP3 (audio)") {
                        convertFile(file, to: "mp3", audioOnly: true)
                    }
                    Button("To GIF") {
                        convertFile(file, to: "gif")
                    }
                    Button("To WebM") {
                        convertFile(file, to: "webm")
                    }
                }
            }
        }
    }

    private func convertFile(_ input: URL, to format: String, audioOnly: Bool = false) {
        let output = input.deletingPathExtension().appendingPathExtension(format)
        var options = FFmpegOptions.default

        if audioOnly {
            options.videoCodec = "copy"
            options.audioCodec = "libmp3lame"
        }

        Task {
            try? await CLIToolManager.shared.convertMedia(
                input: input,
                output: output,
                options: options
            ) { _ in }
        }
    }
}
