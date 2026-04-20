import Foundation

final class DownloadManagerProvider: MCPTaskProvider {
    static let shared = DownloadManagerProvider()

    private let downloadManager = DownloadManager.shared

    func startDownload(url: URL, destination: URL) -> UUID {
        downloadManager.startDownload(url: url, destination: destination).id
    }

    func pauseDownload(id: UUID) {
        downloadManager.pauseDownload(taskId: id)
    }

    func resumeDownload(record: MCPResumeRecord) -> UUID? {
        let downloadRecord = DownloadManager.DownloadRecord(
            id: record.id,
            url: record.url,
            destination: record.destination,
            fileName: record.fileName,
            totalBytes: record.totalBytes,
            downloadedBytes: record.downloadedBytes,
            completedAt: Date(),
            wasResumed: true
        )

        return downloadManager.resumeDownload(record: downloadRecord)?.id
    }

    func repairDownload(id: UUID) {
        downloadManager.repairDownload(taskId: id)
    }

    func getPausedRecords() -> [MCPResumeRecord] {
        downloadManager.pausedTasks.map {
            MCPResumeRecord(
                id: $0.id,
                url: $0.url,
                destination: $0.destination,
                fileName: $0.fileName,
                totalBytes: $0.totalBytes,
                downloadedBytes: $0.downloadedBytes
            )
        }
    }
}
