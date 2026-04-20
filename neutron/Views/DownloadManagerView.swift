import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct DownloadManagerPanelView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var showFilePicker = false
    @State private var downloadURL = ""
    @State private var selectedDestination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @State private var activeTab = 0

    @State private var linkGrabberInput = ""
    @State private var grabbedURLs: [URL] = []

    private var queueTasks: [DownloadTask] { downloadManager.queuedTasks }
    private var runningTasks: [DownloadTask] { downloadManager.runningTasks }
    private var failedTasks: [DownloadTask] { downloadManager.failedTasks }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            managerControls
            linkGrabber

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
            .frame(minHeight: 200)
        }
        .padding()
        .frame(minWidth: 300, minHeight: 400)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedDestination = url
            }
        }
    }

    private var managerControls: some View {
        GroupBox("Download Manager") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("URL:")
                        .frame(width: 70, alignment: .leading)
                    TextField("https://example.com/file.zip", text: $downloadURL)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Save to:")
                        .frame(width: 70, alignment: .leading)
                    Text(selectedDestination.lastPathComponent)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose...") { showFilePicker = true }
                }

                HStack {
                    Text("Queue:")
                        .frame(width: 70, alignment: .leading)

                    Stepper("\(downloadManager.maxSimultaneousDownloads) active", value: $downloadManager.maxSimultaneousDownloads, in: 1...12)
                        .frame(width: 150)

                    Toggle("Multi-connection", isOn: $downloadManager.multiConnectionEnabled)
                        .toggleStyle(.checkbox)

                    Stepper("\(downloadManager.connectionsPerDownload)x", value: $downloadManager.connectionsPerDownload, in: 1...16)
                        .frame(width: 100)
                        .disabled(!downloadManager.multiConnectionEnabled)

                    Spacer()
                }

                HStack {
                    Text("Speed limit:")
                        .frame(width: 70, alignment: .leading)

                    Toggle("Unlimited", isOn: unlimitedBinding)
                        .toggleStyle(.checkbox)

                    Stepper(speedLimitDisplay, value: speedLimitBinding, in: (256 * 1024)...(100 * 1024 * 1024), step: 256 * 1024)
                        .frame(width: 180)
                        .disabled(downloadManager.speedLimitBytesPerSecond == 0)

                    Spacer()
                }

                HStack {
                    Button("Start Download") { startDownload() }
                        .disabled(downloadURL.isEmpty)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var linkGrabber: some View {
        GroupBox("Link Grabber") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $linkGrabberInput)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )

                HStack {
                    Button("Extract Links") {
                        grabbedURLs = extractLinks(from: linkGrabberInput)
                    }
                    Button("Queue All") {
                        _ = downloadManager.startDownloads(urls: grabbedURLs, destinationDirectory: selectedDestination)
                        linkGrabberInput = ""
                        grabbedURLs = []
                    }
                    .disabled(grabbedURLs.isEmpty)

                    Spacer()

                    Text("\(grabbedURLs.count) links")
                        .foregroundColor(.secondary)
                }

                if !grabbedURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(grabbedURLs.prefix(6), id: \.absoluteString) { url in
                            Text(url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if grabbedURLs.count > 6 {
                            Text("…and \(grabbedURLs.count - 6) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
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

    private func extractLinks(from text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive]) else {
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
            guard let url = URL(string: raw), seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }

        return urls
    }

    private func startDownload() {
        guard let url = URL(string: downloadURL) else { return }
        let fileName = downloadURL.split(separator: "/").last ?? "download"
        let destination = selectedDestination.appendingPathComponent(String(fileName))
        _ = downloadManager.startDownload(url: url, destination: destination)
        downloadURL = ""
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
                
                if download.status == .failed {
                    Button("Retry") {
                        // Retry would require restarting with same URL
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.blue)
                }
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
            
            Text("This will attempt to repair the partially downloaded file by requesting only the missing bytes from the server.")
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