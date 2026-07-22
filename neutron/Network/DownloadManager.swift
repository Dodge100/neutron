import Foundation
import Combine
#if canImport(DownloadManagerCore)
import DownloadManagerCore
#endif

final class DownloadTask: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    let destination: URL
    let createdAt: Date

    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var status: DownloadStatus = .pending
    @Published var error: String?
    @Published var resumeData: Data?
    @Published var currentSpeedBytesPerSecond: Double = 0
    @Published var etaSeconds: TimeInterval?
    @Published var retryCount: Int = 0
    @Published var scheduledAt: Date?
    @Published var packageNameOverride: String?
    @Published var priority: DownloadPriority = .normal
    @Published var note: String = ""

    var maxRetries: Int = 5

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }

    var isResumable: Bool {
        status == .paused || status == .failed
    }

    var packageName: String {
        if let packageNameOverride, !packageNameOverride.isEmpty {
            return packageNameOverride
        }
        return url.host ?? "General"
    }

    enum DownloadStatus: String {
        case pending
        case downloading
        case paused
        case repairing
        case extracting
        case completed
        case failed
    }

    init(
        id: UUID = UUID(),
        url: URL,
        destination: URL,
        scheduledAt: Date? = nil,
        packageNameOverride: String? = nil,
        priority: DownloadPriority = .normal,
        note: String = ""
    ) {
        self.id = id
        self.url = url
        self.destination = destination
        self.createdAt = Date()
        self.scheduledAt = scheduledAt
        self.packageNameOverride = packageNameOverride
        self.priority = priority
        self.note = note
    }
}

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    struct DownloadRecord: Codable, Identifiable {
        let id: UUID
        let url: URL
        let destination: URL
        let fileName: String
        let totalBytes: Int64
        let downloadedBytes: Int64
        let completedAt: Date
        let wasResumed: Bool
        let packageName: String?
        let extractedPaths: [URL]
        let priority: DownloadPriority
        let note: String

        enum CodingKeys: String, CodingKey {
            case id
            case url
            case destination
            case fileName
            case totalBytes
            case downloadedBytes
            case completedAt
            case wasResumed
            case packageName
            case extractedPaths
            case priority
            case note
        }

        init(
            id: UUID,
            url: URL,
            destination: URL,
            fileName: String,
            totalBytes: Int64,
            downloadedBytes: Int64,
            completedAt: Date,
            wasResumed: Bool,
            packageName: String?,
            extractedPaths: [URL],
            priority: DownloadPriority,
            note: String
        ) {
            self.id = id
            self.url = url
            self.destination = destination
            self.fileName = fileName
            self.totalBytes = totalBytes
            self.downloadedBytes = downloadedBytes
            self.completedAt = completedAt
            self.wasResumed = wasResumed
            self.packageName = packageName
            self.extractedPaths = extractedPaths
            self.priority = priority
            self.note = note
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            url = try container.decode(URL.self, forKey: .url)
            destination = try container.decode(URL.self, forKey: .destination)
            fileName = try container.decode(String.self, forKey: .fileName)
            totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
            downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
            completedAt = try container.decode(Date.self, forKey: .completedAt)
            wasResumed = try container.decode(Bool.self, forKey: .wasResumed)
            packageName = try container.decodeIfPresent(String.self, forKey: .packageName)
            extractedPaths = try container.decodeIfPresent([URL].self, forKey: .extractedPaths) ?? []
            priority = try container.decodeIfPresent(DownloadPriority.self, forKey: .priority) ?? .normal
            note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        }

        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(downloadedBytes) / Double(totalBytes)
        }
    }

    struct ManagerSettings: Codable {
        var maxSimultaneousDownloads: Int
        var multiConnectionEnabled: Bool
        var connectionsPerDownload: Int
        var speedLimitBytesPerSecond: Int64
        var sourceSpeedLimits: [String: Int64]
        var sourceConnectionLimits: [String: Int]
        var pauseModeEnabled: Bool
        var pauseModeSpeedLimitBytesPerSecond: Int64
        var autoExtractArchives: Bool
        var packagizerRules: [DownloadPackagizerRule]
        var queueOrder: DownloadQueueOrder
        var preventDuplicateURLs: Bool
        var filenamePrefixTemplate: String
        var filenameSuffixTemplate: String
        var defaultScheduleDelayMinutes: Int
        var defaultMaxRetries: Int
        var autoCleanupCompletedDays: Int

        enum CodingKeys: String, CodingKey {
            case maxSimultaneousDownloads
            case multiConnectionEnabled
            case connectionsPerDownload
            case speedLimitBytesPerSecond
            case sourceSpeedLimits
            case sourceConnectionLimits
            case pauseModeEnabled
            case pauseModeSpeedLimitBytesPerSecond
            case autoExtractArchives
            case packagizerRules
            case queueOrder
            case preventDuplicateURLs
            case filenamePrefixTemplate
            case filenameSuffixTemplate
            case defaultScheduleDelayMinutes
            case defaultMaxRetries
            case autoCleanupCompletedDays
        }

        init(
            maxSimultaneousDownloads: Int,
            multiConnectionEnabled: Bool,
            connectionsPerDownload: Int,
            speedLimitBytesPerSecond: Int64,
            sourceSpeedLimits: [String: Int64],
            sourceConnectionLimits: [String: Int],
            pauseModeEnabled: Bool,
            pauseModeSpeedLimitBytesPerSecond: Int64,
            autoExtractArchives: Bool,
            packagizerRules: [DownloadPackagizerRule],
            queueOrder: DownloadQueueOrder,
            preventDuplicateURLs: Bool,
            filenamePrefixTemplate: String,
            filenameSuffixTemplate: String,
            defaultScheduleDelayMinutes: Int,
            defaultMaxRetries: Int,
            autoCleanupCompletedDays: Int
        ) {
            self.maxSimultaneousDownloads = maxSimultaneousDownloads
            self.multiConnectionEnabled = multiConnectionEnabled
            self.connectionsPerDownload = connectionsPerDownload
            self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
            self.sourceSpeedLimits = sourceSpeedLimits
            self.sourceConnectionLimits = sourceConnectionLimits
            self.pauseModeEnabled = pauseModeEnabled
            self.pauseModeSpeedLimitBytesPerSecond = pauseModeSpeedLimitBytesPerSecond
            self.autoExtractArchives = autoExtractArchives
            self.packagizerRules = packagizerRules
            self.queueOrder = queueOrder
            self.preventDuplicateURLs = preventDuplicateURLs
            self.filenamePrefixTemplate = filenamePrefixTemplate
            self.filenameSuffixTemplate = filenameSuffixTemplate
            self.defaultScheduleDelayMinutes = defaultScheduleDelayMinutes
            self.defaultMaxRetries = defaultMaxRetries
            self.autoCleanupCompletedDays = autoCleanupCompletedDays
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            maxSimultaneousDownloads = try container.decode(Int.self, forKey: .maxSimultaneousDownloads)
            multiConnectionEnabled = try container.decode(Bool.self, forKey: .multiConnectionEnabled)
            connectionsPerDownload = try container.decode(Int.self, forKey: .connectionsPerDownload)
            speedLimitBytesPerSecond = try container.decode(Int64.self, forKey: .speedLimitBytesPerSecond)
            sourceSpeedLimits = try container.decodeIfPresent([String: Int64].self, forKey: .sourceSpeedLimits) ?? [:]
            sourceConnectionLimits = try container.decodeIfPresent([String: Int].self, forKey: .sourceConnectionLimits) ?? [:]
            pauseModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .pauseModeEnabled) ?? false
            pauseModeSpeedLimitBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .pauseModeSpeedLimitBytesPerSecond) ?? (512 * 1024)
            autoExtractArchives = try container.decodeIfPresent(Bool.self, forKey: .autoExtractArchives) ?? false
            packagizerRules = try container.decodeIfPresent([DownloadPackagizerRule].self, forKey: .packagizerRules) ?? []
            queueOrder = try container.decodeIfPresent(DownloadQueueOrder.self, forKey: .queueOrder) ?? DownloadQueueOrder()
            preventDuplicateURLs = try container.decodeIfPresent(Bool.self, forKey: .preventDuplicateURLs) ?? false
            filenamePrefixTemplate = try container.decodeIfPresent(String.self, forKey: .filenamePrefixTemplate) ?? ""
            filenameSuffixTemplate = try container.decodeIfPresent(String.self, forKey: .filenameSuffixTemplate) ?? ""
            defaultScheduleDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultScheduleDelayMinutes) ?? 0
            defaultMaxRetries = try container.decodeIfPresent(Int.self, forKey: .defaultMaxRetries) ?? 5
            autoCleanupCompletedDays = try container.decodeIfPresent(Int.self, forKey: .autoCleanupCompletedDays) ?? 0
        }
    }

    struct PersistedSegment: Codable {
        let index: Int
        let lowerBound: Int64
        let upperBound: Int64
        let tempFileName: String?
        let completed: Bool
    }

    struct SegmentResumeManifest: Codable {
        let taskID: UUID
        let url: URL
        let destination: URL
        let totalBytes: Int64
        let segments: [PersistedSegment]
    }

    struct SegmentDownload {
        let index: Int
        let range: ClosedRange<Int64>
        var urlTask: URLSessionDownloadTask?
        var bytesWritten: Int64
        var tempFileURL: URL?
        var completed: Bool
    }

    struct ActiveDownload {
        let task: DownloadTask
        var singleTask: URLSessionDownloadTask?
        var isSegmented: Bool
        var segments: [Int: SegmentDownload]
        var startTime: Date
        var lastSpeedCheck: Date
        var bytesAtLastCheck: Int64
        var tempDirectory: URL?

        var runningNetworkTasks: Int {
            let single = singleTask == nil ? 0 : 1
            let segmentsCount = segments.values.filter { $0.urlTask != nil }.count
            return single + segmentsCount
        }
    }

    @Published var activeTasks: [UUID: ActiveDownload] = [:]
    @Published var completedTasks: [DownloadRecord] = []
    @Published var pausedTasks: [DownloadRecord] = []

    // JD2-like controls
    @Published var maxSimultaneousDownloads: Int = 4 {
        didSet {
            maxSimultaneousDownloads = min(max(maxSimultaneousDownloads, 1), 12)
            saveManagerSettings()
            scheduleNextDownloads()
        }
    }
    @Published var multiConnectionEnabled: Bool = true {
        didSet {
            saveManagerSettings()
            scheduleNextDownloads()
        }
    }
    @Published var connectionsPerDownload: Int = 4 {
        didSet {
            connectionsPerDownload = min(max(connectionsPerDownload, 1), 16)
            saveManagerSettings()
        }
    }
    @Published var speedLimitBytesPerSecond: Int64 = 0 {
        didSet {
            speedLimitBytesPerSecond = max(speedLimitBytesPerSecond, 0)
            saveManagerSettings()
        }
    }
    @Published var sourceSpeedLimits: [String: Int64] = [:] {
        didSet { saveManagerSettings() }
    }
    @Published var sourceConnectionLimits: [String: Int] = [:] {
        didSet { saveManagerSettings() }
    }
    @Published var pauseModeEnabled: Bool = false {
        didSet {
            saveManagerSettings()
            if !pauseModeEnabled {
                scheduleNextDownloads()
            }
        }
    }
    @Published var pauseModeSpeedLimitBytesPerSecond: Int64 = 512 * 1024 {
        didSet {
            pauseModeSpeedLimitBytesPerSecond = max(pauseModeSpeedLimitBytesPerSecond, 64 * 1024)
            saveManagerSettings()
        }
    }
    @Published var autoExtractArchives: Bool = false {
        didSet { saveManagerSettings() }
    }
    @Published var packagizerRules: [DownloadPackagizerRule] = [] {
        didSet { saveManagerSettings() }
    }
    @Published var preventDuplicateURLs: Bool = false {
        didSet { saveManagerSettings() }
    }
    @Published var filenamePrefixTemplate: String = "" {
        didSet { saveManagerSettings() }
    }
    @Published var filenameSuffixTemplate: String = "" {
        didSet { saveManagerSettings() }
    }
    @Published var defaultScheduleDelayMinutes: Int = 0 {
        didSet {
            defaultScheduleDelayMinutes = max(defaultScheduleDelayMinutes, 0)
            saveManagerSettings()
        }
    }
    @Published var defaultMaxRetries: Int = 5 {
        didSet {
            defaultMaxRetries = min(max(defaultMaxRetries, 1), 20)
            saveManagerSettings()
        }
    }
    @Published var autoCleanupCompletedDays: Int = 0 {
        didSet {
            autoCleanupCompletedDays = max(autoCleanupCompletedDays, 0)
            pruneCompletedTasksIfNeeded()
            saveManagerSettings()
        }
    }

    private var urlSession: URLSession!
    private let queue = DispatchQueue(label: "com.neutron.downloadmanager", qos: .userInitiated)
    private let repairThreshold: Double = 0.9
    private let minimumSegmentSize: Int64 = 2 * 1024 * 1024

    private let applicationSupportURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }()

    private var queuedResumeData: [UUID: Data] = [:]
    private var queuedSegmentManifests: [UUID: SegmentResumeManifest] = [:]
    private var isThrottling = false
    private var throttledSources: Set<String> = []
    private var queueOrder = DownloadQueueOrder()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var saveWorkItem: DispatchWorkItem?

    override init() {
        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.httpMaximumConnectionsPerHost = 32

        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        loadManagerSettings()
        loadCompletedTasks()
        loadPausedTasks()
        pruneCompletedTasksIfNeeded()
    }

    // MARK: - Public API

    func startDownload(url: URL, destination: URL) -> DownloadTask {
        if preventDuplicateURLs, let existing = existingTask(for: url) {
            return existing
        }

        let task = createManagedTask(url: url, destination: destination)
        enqueueOrStart(task)
        return task
    }

    func enqueueDownload(url: URL, destination: URL) -> DownloadTask {
        if preventDuplicateURLs, let existing = existingTask(for: url) {
            return existing
        }

        let task = createManagedTask(url: url, destination: destination)
        task.status = .pending
        return task
    }

    private func createManagedTask(url: URL, destination: URL) -> DownloadTask {
        let templatedDestination = DownloadFileNameTemplate.apply(
            destination: destination,
            sourceURL: url,
            prefixTemplate: filenamePrefixTemplate,
            suffixTemplate: filenameSuffixTemplate
        )
        let packagized = DownloadPackagizer.apply(url: url, destination: templatedDestination, rules: packagizerRules)
        let task = DownloadTask(
            url: url,
            destination: packagized.destination,
            scheduledAt: DownloadSchedulePolicy.scheduledDate(defaultDelayMinutes: defaultScheduleDelayMinutes),
            packageNameOverride: packagized.packageNameOverride,
            priority: .normal,
            note: ""
        )
        task.maxRetries = defaultMaxRetries

        let active = ActiveDownload(
            task: task,
            singleTask: nil,
            isSegmented: false,
            segments: [:],
            startTime: Date(),
            lastSpeedCheck: Date(),
            bytesAtLastCheck: 0,
            tempDirectory: nil
        )

        activeTasks[task.id] = active
        queueOrder.insertIfNeeded(task.id)
        saveManagerSettings()
        return task
    }

    private func existingTask(for url: URL) -> DownloadTask? {
        activeTasks.values.map(\.task).first { $0.url.absoluteString == url.absoluteString }
    }

    func resumeDownload(record: DownloadRecord) -> DownloadTask? {
        let task = DownloadTask(
            id: record.id,
            url: record.url,
            destination: record.destination,
            packageNameOverride: record.packageName,
            priority: record.priority,
            note: record.note
        )
        task.downloadedBytes = record.downloadedBytes
        task.totalBytes = record.totalBytes
        task.maxRetries = defaultMaxRetries

        let active = ActiveDownload(
            task: task,
            singleTask: nil,
            isSegmented: false,
            segments: [:],
            startTime: Date(),
            lastSpeedCheck: Date(),
            bytesAtLastCheck: record.downloadedBytes,
            tempDirectory: nil
        )

        activeTasks[task.id] = active
        queueOrder.insertIfNeeded(task.id)

        if let manifest = loadSegmentManifest(for: record.id) {
            queuedSegmentManifests[task.id] = manifest
        } else if let resumeData = loadResumeData(for: record.id) {
            queuedResumeData[task.id] = resumeData
        }

        removePausedTask(task.id)
        enqueueOrStart(task)
        return task
    }

    func pauseDownload(taskId: UUID) {
        guard let active = activeTasks[taskId] else { return }

        if active.task.status == .pending {
            active.task.status = .paused
            savePausedTask(makePausedRecord(from: active.task))
            activeTasks.removeValue(forKey: taskId)
            queueOrder.remove(taskId)
            saveManagerSettings()
            queuedResumeData.removeValue(forKey: taskId)
            cleanupTemporaryArtifacts(for: taskId)
            scheduleNextDownloads()
            return
        }

        if active.isSegmented {
            active.segments.values.forEach { $0.urlTask?.cancel() }
            active.task.status = .paused
            active.task.resumeData = nil
            var pausedActive = active
            pausedActive.segments = pausedActive.segments.mapValues { segment in
                var updated = segment
                updated.urlTask = nil
                updated.bytesWritten = segment.completed ? (segment.range.upperBound - segment.range.lowerBound + 1) : 0
                return updated
            }
            saveSegmentManifest(makeSegmentManifest(from: pausedActive))
            savePausedTask(makePausedRecord(from: active.task))
            activeTasks.removeValue(forKey: taskId)
            queueOrder.remove(taskId)
            saveManagerSettings()
            scheduleNextDownloads()
            return
        }

        guard let singleTask = active.singleTask else { return }
        singleTask.cancel { [weak self] resumeData in
            guard let self else { return }
            DispatchQueue.main.async {
                active.task.status = .paused
                active.task.resumeData = resumeData
                self.saveResumeData(resumeData, for: taskId)
                self.savePausedTask(self.makePausedRecord(from: active.task))
                self.activeTasks.removeValue(forKey: taskId)
                self.queueOrder.remove(taskId)
                self.saveManagerSettings()
                self.scheduleNextDownloads()
            }
        }
    }

    func cancelDownload(taskId: UUID) {
        guard let active = activeTasks[taskId] else { return }

        active.singleTask?.cancel()
        active.segments.values.forEach { $0.urlTask?.cancel() }

        activeTasks.removeValue(forKey: taskId)
        queueOrder.remove(taskId)
        saveManagerSettings()
        queuedResumeData.removeValue(forKey: taskId)
        queuedSegmentManifests.removeValue(forKey: taskId)
        deleteResumeData(for: taskId)
        removePausedTask(taskId)
        deleteSegmentManifest(for: taskId)
        cleanupTemporaryArtifacts(for: taskId)

        DispatchQueue.main.async {
            active.task.status = .failed
            active.task.error = "Cancelled"
        }

        scheduleNextDownloads()
    }

    func retryDownload(taskId: UUID) {
        guard let active = activeTasks[taskId] else { return }
        active.task.error = nil
        active.task.status = .pending
        enqueueOrStart(active.task)
    }

    func repairDownload(taskId: UUID) {
        guard let active = activeTasks[taskId] else { return }

        DispatchQueue.main.async {
            active.task.status = .repairing
        }

        queue.async { [weak self] in
            self?.performRepair(for: active.task)
        }
    }

    func startDownloads(urls: [URL], destinationDirectory: URL, startImmediately: Bool = true) -> [DownloadTask] {
        let existingURLs = Set(activeTasks.values.map { $0.task.url.absoluteString } + pausedTasks.map { $0.url.absoluteString })
        let filteredURLs = DownloadDuplicatePolicy.filterIncomingURLs(
            urls,
            existingAbsoluteURLs: existingURLs,
            preventDuplicates: preventDuplicateURLs
        )

        var reserved = Set<String>()
        return filteredURLs.map { url in
            let destination = DownloadLinkGrabber.destinationURL(
                for: url,
                baseDirectory: destinationDirectory,
                existingPaths: reserved
            )
            reserved.insert(destination.path)
            return startImmediately
                ? startDownload(url: url, destination: destination)
                : enqueueDownload(url: url, destination: destination)
        }
    }

    func setScheduledStart(taskId: UUID, date: Date?) {
        guard let active = activeTasks[taskId] else { return }
        active.task.scheduledAt = date
        if active.task.status == .pending {
            scheduleNextDownloads()
        }
    }

    func moveQueuedTask(taskId: UUID, action: QueueMoveAction) {
        queueOrder.move(taskId, action: action)
        saveManagerSettings()
    }

    func addPackagizerRule(_ rule: DownloadPackagizerRule) {
        packagizerRules.append(rule)
    }

    func removePackagizerRule(_ id: UUID) {
        packagizerRules.removeAll { $0.id == id }
    }

    func setPriority(taskId: UUID, priority: DownloadPriority) {
        guard let active = activeTasks[taskId] else { return }
        active.task.priority = priority
    }

    func setNote(taskId: UUID, note: String) {
        guard let active = activeTasks[taskId] else { return }
        active.task.note = note
    }

    func pauseAllDownloads() {
        let ids = Array(activeTasks.keys)
        ids.forEach { pauseDownload(taskId: $0) }
    }

    func resumeAllDownloads() {
        let records = pausedTasks
        records.forEach { _ = resumeDownload(record: $0) }
    }

    func clearCompletedTasks() {
        completedTasks = []
        saveCompletedTasks()
    }

    var runningTasks: [DownloadTask] {
        activeTasks.values
            .map(\.task)
            .filter { $0.status == .downloading || $0.status == .repairing }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var queuedTasks: [DownloadTask] {
        let pending = activeTasks.values
            .map(\.task)
            .filter { $0.status == .pending }
        return DownloadPriorityQueueSorter.sort(
            pending,
            priority: { $0.priority },
            queueOrder: queueOrder,
            fallback: { $0.createdAt < $1.createdAt }
        )
    }

    var failedTasks: [DownloadTask] {
        activeTasks.values
            .map(\.task)
            .filter { $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func getTask(for id: UUID) -> DownloadTask? { activeTasks[id]?.task }
    func getAllTasks() -> [DownloadTask] { activeTasks.values.map(\.task) }

    func setSourceSpeedLimit(for source: String, bytesPerSecond: Int64) {
        let key = normalizedSourceKey(source)
        if bytesPerSecond <= 0 {
            sourceSpeedLimits.removeValue(forKey: key)
        } else {
            sourceSpeedLimits[key] = bytesPerSecond
        }
    }

    func sourceSpeedLimit(for source: String) -> Int64 {
        sourceSpeedLimits[normalizedSourceKey(source)] ?? 0
    }

    func setSourceConnectionLimit(for source: String, limit: Int) {
        let key = normalizedSourceKey(source)
        if limit <= 0 {
            sourceConnectionLimits.removeValue(forKey: key)
        } else {
            sourceConnectionLimits[key] = min(max(limit, 1), 16)
        }
    }

    func sourceConnectionLimit(for source: String) -> Int {
        sourceConnectionLimits[normalizedSourceKey(source)] ?? max(maxSimultaneousDownloads, connectionsPerDownload)
    }

    func knownSources() -> [String] {
        let fromActive = activeTasks.values.compactMap { $0.task.url.host?.lowercased() }
        let fromCompleted = completedTasks.compactMap { $0.url.host?.lowercased() }
        let fromPaused = pausedTasks.compactMap { $0.url.host?.lowercased() }
        return Array(Set(fromActive + fromCompleted + fromPaused + Array(sourceSpeedLimits.keys) + Array(sourceConnectionLimits.keys))).sorted()
    }

    // MARK: - Queue / Scheduling

    private func enqueueOrStart(_ task: DownloadTask) {
        let source = sourceKey(for: task.url)
        if runningTasks.count < maxSimultaneousDownloads,
           canStartTask(forSource: source),
           DownloadStartPolicy.canStart(pauseModeEnabled: pauseModeEnabled, scheduledAt: task.scheduledAt) {
            startNetworkTask(for: task)
        } else {
            task.status = .pending
        }
    }

    private func scheduleNextDownloads() {
        var free = max(0, maxSimultaneousDownloads - runningTasks.count)
        guard free > 0 else { return }

        for task in queuedTasks {
            guard free > 0 else { break }
            guard DownloadStartPolicy.canStart(pauseModeEnabled: pauseModeEnabled, scheduledAt: task.scheduledAt) else { continue }
            let source = sourceKey(for: task.url)
            guard canStartTask(forSource: source) else { continue }
            startNetworkTask(for: task)
            free -= 1
        }
    }

    private func startNetworkTask(for task: DownloadTask) {
        guard DownloadStartPolicy.canStart(pauseModeEnabled: pauseModeEnabled, scheduledAt: task.scheduledAt) else {
            task.status = .pending
            return
        }

        if let manifest = queuedSegmentManifests.removeValue(forKey: task.id) {
            startSegmentedDownloadTask(for: task, totalBytes: manifest.totalBytes, manifest: manifest)
            return
        }

        if let active = activeTasks[task.id], active.isSegmented, !active.segments.isEmpty {
            startSegmentedDownloadTask(
                for: task,
                totalBytes: max(task.totalBytes, active.task.totalBytes),
                manifest: makeSegmentManifest(from: active)
            )
            return
        }

        if let resumeData = queuedResumeData.removeValue(forKey: task.id) {
            startSingleDownloadTask(for: task, resumeData: resumeData)
            return
        }

        guard multiConnectionEnabled else {
            startSingleDownloadTask(for: task, resumeData: nil)
            return
        }

        probeServerForSegmentation(task.url) { [weak self] canSegment, totalBytes in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.activeTasks[task.id] != nil else { return }
                guard DownloadStartPolicy.canStart(pauseModeEnabled: self.pauseModeEnabled, scheduledAt: task.scheduledAt) else {
                    task.status = .pending
                    return
                }

                if canSegment,
                   totalBytes > self.minimumSegmentSize,
                   self.connectionsPerDownload > 1 {
                    self.startSegmentedDownloadTask(for: task, totalBytes: totalBytes)
                } else {
                    self.startSingleDownloadTask(for: task, resumeData: nil)
                }
            }
        }
    }

    private func startSingleDownloadTask(for task: DownloadTask, resumeData: Data?) {
        let urlTask: URLSessionDownloadTask
        if let resumeData {
            urlTask = urlSession.downloadTask(withResumeData: resumeData)
        } else {
            urlTask = urlSession.downloadTask(with: task.url)
        }

        urlTask.taskDescription = "single|\(task.id.uuidString)"

        if var active = activeTasks[task.id] {
            active.singleTask = urlTask
            active.isSegmented = false
            active.segments = [:]
            active.startTime = Date()
            active.lastSpeedCheck = Date()
            active.bytesAtLastCheck = task.downloadedBytes
            active.tempDirectory = nil
            activeTasks[task.id] = active
        }

        task.error = nil
        task.status = .downloading
        urlTask.resume()
    }

    private func startSegmentedDownloadTask(
        for task: DownloadTask,
        totalBytes: Int64,
        manifest: SegmentResumeManifest? = nil
    ) {
        guard var active = activeTasks[task.id] else { return }

        let resolvedTotalBytes = manifest?.totalBytes ?? totalBytes
        let ranges = manifest?.segments.sorted { $0.index < $1.index }.map { $0.lowerBound...$0.upperBound }
            ?? buildRanges(totalBytes: resolvedTotalBytes, chunkSize: preferredChunkSize(for: resolvedTotalBytes))
        guard ranges.count > 1 else {
            startSingleDownloadTask(for: task, resumeData: nil)
            return
        }

        task.totalBytes = resolvedTotalBytes
        task.error = nil
        task.status = .downloading

        let tempDir = segmentedTempDirectory(for: task.id)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        active.isSegmented = true
        active.singleTask = nil
        active.segments = [:]
        active.tempDirectory = tempDir
        active.startTime = Date()
        active.lastSpeedCheck = Date()
        active.bytesAtLastCheck = 0

        let persistedSegments = manifest?.segments.sorted { $0.index < $1.index }
        let segmentsSource = persistedSegments ?? ranges.enumerated().map { index, range in
            PersistedSegment(index: index, lowerBound: range.lowerBound, upperBound: range.upperBound, tempFileName: nil, completed: false)
        }

        var totalWritten: Int64 = 0
        for segmentState in segmentsSource {
            let range = segmentState.lowerBound...segmentState.upperBound
            let partURL = segmentState.tempFileName.map { tempDir.appendingPathComponent($0) }
            let completed = segmentState.completed && partURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
            let bytesWritten = completed ? (range.upperBound - range.lowerBound + 1) : 0

            active.segments[segmentState.index] = SegmentDownload(
                index: segmentState.index,
                range: range,
                urlTask: nil,
                bytesWritten: bytesWritten,
                tempFileURL: completed ? partURL : nil,
                completed: completed
            )
            totalWritten += bytesWritten
        }

        task.downloadedBytes = totalWritten
        active.bytesAtLastCheck = totalWritten
        activeTasks[task.id] = active
        saveSegmentManifest(makeSegmentManifest(from: active))
        scheduleNextSegmentChunks(for: task.id)
    }

    private func preferredChunkSize(for totalBytes: Int64) -> Int64 {
        DownloadSegmentPlanner.preferredChunkSize(
            totalBytes: totalBytes,
            connectionsPerDownload: connectionsPerDownload,
            minimumSegmentSize: minimumSegmentSize
        )
    }

    private func buildRanges(totalBytes: Int64, chunkSize: Int64) -> [ClosedRange<Int64>] {
        DownloadSegmentPlanner.buildRanges(totalBytes: totalBytes, chunkSize: chunkSize)
    }

    private func scheduleNextSegmentChunks(for taskId: UUID) {
        guard var active = activeTasks[taskId], active.isSegmented else { return }
        guard active.task.status == .downloading else { return }

        let source = sourceKey(for: active.task.url)
        let sourceLimit = sourceConnectionLimit(for: source)
        let otherConnections = max(0, activeNetworkConnections(forSource: source) - active.runningNetworkTasks)
        let maxForTask = max(1, min(connectionsPerDownload, sourceLimit - otherConnections))
        let runningCount = active.segments.values.filter { $0.urlTask != nil }.count
        guard runningCount < maxForTask else { return }

        let availableSlots = maxForTask - runningCount
        let pendingIndexes = active.segments.values
            .filter { !$0.completed && $0.urlTask == nil }
            .sorted { $0.index < $1.index }
            .prefix(availableSlots)
            .map(\.index)

        guard !pendingIndexes.isEmpty else { return }

        for index in pendingIndexes {
            guard var segment = active.segments[index] else { continue }
            var request = URLRequest(url: active.task.url)
            request.setValue("bytes=\(segment.range.lowerBound)-\(segment.range.upperBound)", forHTTPHeaderField: "Range")

            let segmentTask = urlSession.downloadTask(with: request)
            segmentTask.taskDescription = "segment|\(taskId.uuidString)|\(index)"
            segment.urlTask = segmentTask
            active.segments[index] = segment
            segmentTask.resume()
        }

        activeTasks[taskId] = active
    }

    private func probeServerForSegmentation(_ url: URL, completion: @escaping (Bool, Int64) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(false, 0)
                return
            }

            let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
            let supports = ranges.contains("bytes")

            let contentLengthHeader = http.value(forHTTPHeaderField: "Content-Length")
            let headerLength = Int64(contentLengthHeader ?? "") ?? 0
            let expectedLength = max(http.expectedContentLength, 0)
            let total = headerLength > 0 ? headerLength : expectedLength

            completion(supports && total > 0, total)
        }
        .resume()
    }

    // MARK: - Progress / Speed

    private func updateProgressAndSpeed(taskId: UUID, totalWritten: Int64, expectedTotal: Int64?) {
        guard var active = activeTasks[taskId] else { return }

        active.task.downloadedBytes = totalWritten
        if let expectedTotal, expectedTotal > 0 {
            active.task.totalBytes = expectedTotal
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(active.lastSpeedCheck)
        if elapsed >= 0.5 {
            let bytesDiff = totalWritten - active.bytesAtLastCheck
            let speed = max(0, Double(bytesDiff) / max(elapsed, 0.001))
            active.task.currentSpeedBytesPerSecond = speed

            let remaining = max(0, active.task.totalBytes - totalWritten)
            active.task.etaSeconds = speed > 0 ? Double(remaining) / speed : nil

            active.lastSpeedCheck = now
            active.bytesAtLastCheck = totalWritten
            activeTasks[taskId] = active

            enforceSpeedLimitsIfNeeded()
        } else {
            activeTasks[taskId] = active
        }
    }

    private func enforceSpeedLimitsIfNeeded() {
        let activeGlobalLimit: Int64 = {
            if pauseModeEnabled {
                return max(pauseModeSpeedLimitBytesPerSecond, 64 * 1024)
            }
            return speedLimitBytesPerSecond
        }()

        if activeGlobalLimit > 0, !isThrottling {
            let aggregateSpeed = runningTasks.reduce(0.0) { $0 + $1.currentSpeedBytesPerSecond }
            if aggregateSpeed > Double(activeGlobalLimit) {
                isThrottling = true
                throttleTasks(
                    matching: { _ in true },
                    pauseDuration: throttlePauseDuration(current: aggregateSpeed, limit: Double(activeGlobalLimit))
                ) { [weak self] in
                    self?.isThrottling = false
                }
            }
        }

        for (source, limitValue) in sourceSpeedLimits {
            guard limitValue > 0, !throttledSources.contains(source) else { continue }

            let matchingTasks = runningTasks.filter { sourceKey(for: $0.url) == source }
            guard !matchingTasks.isEmpty else { continue }

            let currentSpeed = matchingTasks.reduce(0.0) { $0 + $1.currentSpeedBytesPerSecond }
            let limit = Double(limitValue)
            guard currentSpeed > limit else { continue }

            throttledSources.insert(source)
            throttleTasks(
                matching: { self.sourceKey(for: $0.task.url) == source },
                pauseDuration: throttlePauseDuration(current: currentSpeed, limit: limit)
            ) { [weak self] in
                self?.throttledSources.remove(source)
            }
        }
    }

    private func throttlePauseDuration(current: Double, limit: Double) -> TimeInterval {
        guard current > 0, limit > 0 else { return 0.12 }
        let overageRatio = min(1.0, max(0.05, (current - limit) / current))
        return min(0.45, max(0.08, overageRatio * 0.36))
    }

    private func throttleTasks(
        matching predicate: @escaping (ActiveDownload) -> Bool,
        pauseDuration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let matching = activeTasks.values.filter { $0.task.status == .downloading && predicate($0) }
        guard !matching.isEmpty else {
            completion()
            return
        }

        for active in matching {
            active.singleTask?.suspend()
            active.segments.values.forEach { $0.urlTask?.suspend() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pauseDuration) { [weak self] in
            guard let self else { return }
            let stillRunning = self.activeTasks.values.filter { $0.task.status == .downloading && predicate($0) }
            for active in stillRunning {
                active.singleTask?.resume()
                active.segments.values.forEach { $0.urlTask?.resume() }
            }
            completion()
        }
    }

    private func canStartTask(forSource source: String) -> Bool {
        runningDownloadsCount(forSource: source) < sourceConnectionLimit(for: source)
    }

    private func runningDownloadsCount(forSource source: String) -> Int {
        activeTasks.values.filter {
            ($0.task.status == .downloading || $0.task.status == .repairing)
            && sourceKey(for: $0.task.url) == source
        }.count
    }

    private func activeNetworkConnections(forSource source: String) -> Int {
        activeTasks.values
            .filter { sourceKey(for: $0.task.url) == source }
            .reduce(0) { $0 + $1.runningNetworkTasks }
    }

    private func sourceKey(for url: URL) -> String {
        normalizedSourceKey(url.host ?? "general")
    }

    private func normalizedSourceKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Completion / Failure

    private func completeTask(_ task: DownloadTask, extractedPaths: [URL] = []) {
        let record = DownloadRecord(
            id: task.id,
            url: task.url,
            destination: task.destination,
            fileName: task.destination.lastPathComponent,
            totalBytes: task.totalBytes,
            downloadedBytes: task.downloadedBytes,
            completedAt: Date(),
            wasResumed: task.retryCount > 0,
            packageName: task.packageNameOverride,
            extractedPaths: extractedPaths,
            priority: task.priority,
            note: task.note
        )

        completedTasks.insert(record, at: 0)
        pruneCompletedTasksIfNeeded()
        saveCompletedTasks()

        activeTasks.removeValue(forKey: task.id)
        queueOrder.remove(task.id)
        removePausedTask(task.id)
        deleteResumeData(for: task.id)
        queuedResumeData.removeValue(forKey: task.id)
        queuedSegmentManifests.removeValue(forKey: task.id)
        deleteSegmentManifest(for: task.id)
        cleanupTemporaryArtifacts(for: task.id)
        saveManagerSettings()
        scheduleNextDownloads()
    }

    private func finalizeSuccessfulDownload(_ task: DownloadTask) {
        if autoExtractArchives,
           task.destination.pathExtension.lowercased() == "zip" {
            task.status = .extracting
            queue.async {
                let extractDirectory = task.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(task.destination.deletingPathExtension().lastPathComponent, isDirectory: true)
                let extracted = (try? DownloadArchiveExtractor.extractIfNeeded(
                    sourceFileURL: task.destination,
                    destinationDirectory: extractDirectory,
                    isEnabled: true
                )) == true

                DispatchQueue.main.async {
                    task.status = .completed
                    self.completeTask(task, extractedPaths: extracted ? [extractDirectory] : [])
                }
            }
            return
        }

        task.status = .completed
        completeTask(task)
    }

    private func handleFailure(taskId: UUID, error: Error, resumeData: Data?) {
        guard var active = activeTasks[taskId] else { return }

        if active.task.retryCount < active.task.maxRetries {
            active.task.retryCount += 1
            active.task.error = "Retry \(active.task.retryCount)/\(active.task.maxRetries): \(error.localizedDescription)"
            active.task.status = .pending

            if active.isSegmented {
                active.segments = active.segments.mapValues { segment in
                    var updated = segment
                    updated.urlTask = nil
                    updated.bytesWritten = segment.completed ? (segment.range.upperBound - segment.range.lowerBound + 1) : 0
                    return updated
                }
                activeTasks[taskId] = active
                saveSegmentManifest(makeSegmentManifest(from: active))
            }

            if let resumeData {
                queuedResumeData[taskId] = resumeData
                saveResumeData(resumeData, for: taskId)
            }

            if !active.isSegmented {
                cleanupTemporaryArtifacts(for: taskId)
            }

            let backoff = min(pow(2.0, Double(active.task.retryCount - 1)), 20)
            DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
                guard let self,
                      let task = self.activeTasks[taskId]?.task,
                      task.status == .pending else { return }
                self.enqueueOrStart(task)
            }
        } else {
            active.task.error = error.localizedDescription
            active.task.status = .failed
            if active.isSegmented {
                saveSegmentManifest(makeSegmentManifest(from: active))
            }
            scheduleNextDownloads()
        }
    }

    // MARK: - Repair

    private func performRepair(for task: DownloadTask) {
        var request = URLRequest(url: task.url)
        request.setValue("bytes=\(task.downloadedBytes)-", forHTTPHeaderField: "Range")

        let repairTask = urlSession.downloadTask(with: request) { [weak self] localURL, _, error in
            guard let self else { return }

            DispatchQueue.main.async {
                task.status = .downloading
            }

            if let error {
                DispatchQueue.main.async {
                    task.error = error.localizedDescription
                    task.status = .failed
                    self.scheduleNextDownloads()
                }
                return
            }

            guard let localURL else { return }

            do {
                let partialData = try Data(contentsOf: localURL)
                let expectedBytes = task.downloadedBytes + Int64(partialData.count)

                if expectedBytes >= Int64(Double(task.totalBytes) * self.repairThreshold) {
                    if FileManager.default.fileExists(atPath: task.destination.path) {
                        try FileManager.default.removeItem(at: task.destination)
                    }
                    try FileManager.default.createDirectory(at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: localURL, to: task.destination)

                    DispatchQueue.main.async {
                        self.finalizeSuccessfulDownload(task)
                    }
                } else {
                    DispatchQueue.main.async {
                        task.downloadedBytes = expectedBytes
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    task.error = error.localizedDescription
                    task.status = .failed
                    self.scheduleNextDownloads()
                }
            }
        }

        repairTask.resume()
    }

    // MARK: - Descriptor Parsing

    private enum Descriptor {
        case single(UUID)
        case segment(taskID: UUID, index: Int)
    }

    private func parseDescriptor(_ taskDescription: String?) -> Descriptor? {
        guard let taskDescription else { return nil }

        let parts = taskDescription.split(separator: "|").map(String.init)
        if parts.count == 2, parts[0] == "single", let id = UUID(uuidString: parts[1]) {
            return .single(id)
        }
        if parts.count == 3,
           parts[0] == "segment",
           let id = UUID(uuidString: parts[1]),
           let idx = Int(parts[2]) {
            return .segment(taskID: id, index: idx)
        }

        // Backward compat: raw UUID string
        if let id = UUID(uuidString: taskDescription) {
            return .single(id)
        }

        return nil
    }

    // MARK: - Segment Merge

    private func mergeSegmentsIfReady(taskId: UUID) {
        guard let active = activeTasks[taskId], active.isSegmented else { return }

        let allComplete = !active.segments.isEmpty && active.segments.values.allSatisfy { $0.completed && $0.tempFileURL != nil }
        guard allComplete else { return }

        do {
            let destination = active.task.destination
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: destination.path, contents: nil)

            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            let ordered = active.segments.keys.sorted()
            for index in ordered {
                guard let fileURL = active.segments[index]?.tempFileURL else { continue }
                let data = try Data(contentsOf: fileURL)
                try output.write(contentsOf: data)
            }

            active.task.downloadedBytes = active.task.totalBytes
            finalizeSuccessfulDownload(active.task)
        } catch {
            handleFailure(taskId: taskId, error: error, resumeData: nil)
        }
    }

    // MARK: - Persistence

    private func makeSegmentManifest(from active: ActiveDownload) -> SegmentResumeManifest {
        let segments = active.segments.values
            .sorted { $0.index < $1.index }
            .map { segment in
                PersistedSegment(
                    index: segment.index,
                    lowerBound: segment.range.lowerBound,
                    upperBound: segment.range.upperBound,
                    tempFileName: segment.tempFileURL?.lastPathComponent,
                    completed: segment.completed
                )
            }

        return SegmentResumeManifest(
            taskID: active.task.id,
            url: active.task.url,
            destination: active.task.destination,
            totalBytes: active.task.totalBytes,
            segments: segments
        )
    }

    private func makePausedRecord(from task: DownloadTask) -> DownloadRecord {
        DownloadRecord(
            id: task.id,
            url: task.url,
            destination: task.destination,
            fileName: task.destination.lastPathComponent,
            totalBytes: task.totalBytes,
            downloadedBytes: task.downloadedBytes,
            completedAt: Date(),
            wasResumed: true,
            packageName: task.packageNameOverride,
            extractedPaths: [],
            priority: task.priority,
            note: task.note
        )
    }

    private func saveResumeData(_ data: Data?, for taskId: UUID) {
        guard let data else { return }
        let url = resumeDataURL(for: taskId)
        try? data.write(to: url)
    }

    private func loadResumeData(for taskId: UUID) -> Data? {
        let url = resumeDataURL(for: taskId)
        return try? Data(contentsOf: url)
    }

    private func deleteResumeData(for taskId: UUID) {
        let url = resumeDataURL(for: taskId)
        try? FileManager.default.removeItem(at: url)
    }

    private func saveSegmentManifest(_ manifest: SegmentResumeManifest) {
        let url = segmentManifestURL(for: manifest.taskID)
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: url)
    }

    private func loadSegmentManifest(for taskId: UUID) -> SegmentResumeManifest? {
        let url = segmentManifestURL(for: taskId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SegmentResumeManifest.self, from: data)
    }

    private func deleteSegmentManifest(for taskId: UUID) {
        let url = segmentManifestURL(for: taskId)
        try? FileManager.default.removeItem(at: url)
    }

    private func resumeDataURL(for taskId: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("neutron/resumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(taskId.uuidString).resume")
    }

    private func segmentManifestURL(for taskId: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("neutron/downloads/manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(taskId.uuidString).json")
    }

    private func saveCompletedTasks() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("neutron/downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("completed.json")

        if let data = try? encoder.encode(completedTasks) {
            try? data.write(to: url)
        }
    }

    private func loadCompletedTasks() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("neutron/downloads/completed.json")

        if let data = try? Data(contentsOf: url),
           let records = try? decoder.decode([DownloadRecord].self, from: data) {
            completedTasks = records
        }
    }

    private func pruneCompletedTasksIfNeeded() {
        let pruned = DownloadHistoryCleanup.prune(
            records: completedTasks,
            keepingDays: autoCleanupCompletedDays,
            date: { $0.completedAt }
        )

        if pruned.count != completedTasks.count {
            completedTasks = pruned
            saveCompletedTasks()
        }
    }

    private func savePausedTask(_ record: DownloadRecord) {
        pausedTasks.removeAll { $0.id == record.id }
        pausedTasks.append(record)
        persistPausedTasks()
    }

    private func removePausedTask(_ taskId: UUID) {
        let before = pausedTasks.count
        pausedTasks.removeAll { $0.id == taskId }
        if pausedTasks.count != before {
            persistPausedTasks()
        }
    }

    private func persistPausedTasks() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("neutron/downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("paused.json")

        if let data = try? encoder.encode(pausedTasks) {
            try? data.write(to: url)
        }
    }

    private func loadPausedTasks() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("neutron/downloads/paused.json")

        if let data = try? Data(contentsOf: url),
           let records = try? decoder.decode([DownloadRecord].self, from: data) {
            pausedTasks = records
        }
    }

    private func saveManagerSettings() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSaveManagerSettings()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func performSaveManagerSettings() {
        let settings = ManagerSettings(
            maxSimultaneousDownloads: maxSimultaneousDownloads,
            multiConnectionEnabled: multiConnectionEnabled,
            connectionsPerDownload: connectionsPerDownload,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond,
            sourceSpeedLimits: sourceSpeedLimits,
            sourceConnectionLimits: sourceConnectionLimits,
            pauseModeEnabled: pauseModeEnabled,
            pauseModeSpeedLimitBytesPerSecond: pauseModeSpeedLimitBytesPerSecond,
            autoExtractArchives: autoExtractArchives,
            packagizerRules: packagizerRules,
            queueOrder: queueOrder,
            preventDuplicateURLs: preventDuplicateURLs,
            filenamePrefixTemplate: filenamePrefixTemplate,
            filenameSuffixTemplate: filenameSuffixTemplate,
            defaultScheduleDelayMinutes: defaultScheduleDelayMinutes,
            defaultMaxRetries: defaultMaxRetries,
            autoCleanupCompletedDays: autoCleanupCompletedDays
        )

        let dir = applicationSupportURL.appendingPathComponent("neutron/downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manager-settings.json")

        if let data = try? encoder.encode(settings) {
            try? data.write(to: url)
        }
    }

    private func loadManagerSettings() {
        let url = applicationSupportURL.appendingPathComponent("neutron/downloads/manager-settings.json")

        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(ManagerSettings.self, from: data) else {
            return
        }

        maxSimultaneousDownloads = min(max(settings.maxSimultaneousDownloads, 1), 12)
        multiConnectionEnabled = settings.multiConnectionEnabled
        connectionsPerDownload = min(max(settings.connectionsPerDownload, 1), 16)
        speedLimitBytesPerSecond = max(settings.speedLimitBytesPerSecond, 0)
        sourceSpeedLimits = settings.sourceSpeedLimits
        sourceConnectionLimits = settings.sourceConnectionLimits
        pauseModeEnabled = settings.pauseModeEnabled
        pauseModeSpeedLimitBytesPerSecond = max(settings.pauseModeSpeedLimitBytesPerSecond, 64 * 1024)
        autoExtractArchives = settings.autoExtractArchives
        packagizerRules = settings.packagizerRules
        queueOrder = settings.queueOrder
        preventDuplicateURLs = settings.preventDuplicateURLs
        filenamePrefixTemplate = settings.filenamePrefixTemplate
        filenameSuffixTemplate = settings.filenameSuffixTemplate
        defaultScheduleDelayMinutes = max(settings.defaultScheduleDelayMinutes, 0)
        defaultMaxRetries = min(max(settings.defaultMaxRetries, 1), 20)
        autoCleanupCompletedDays = max(settings.autoCleanupCompletedDays, 0)
    }

    // MARK: - Temp Artifacts

    private func segmentedTempDirectory(for taskId: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("neutron/downloads/segments", isDirectory: true)
            .appendingPathComponent(taskId.uuidString, isDirectory: true)
        return dir
    }

    private func cleanupTemporaryArtifacts(for taskId: UUID) {
        let dir = segmentedTempDirectory(for: taskId)
        try? FileManager.default.removeItem(at: dir)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let descriptor = parseDescriptor(downloadTask.taskDescription) else { return }

        switch descriptor {
        case .single(let taskId):
            guard let active = activeTasks[taskId] else { return }
            let destination = active.task.destination

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: destination)

                DispatchQueue.main.async {
                    self.finalizeSuccessfulDownload(active.task)
                }
            } catch {
                DispatchQueue.main.async {
                    self.handleFailure(taskId: taskId, error: error, resumeData: nil)
                }
            }

        case .segment(let taskId, let index):
            guard var active = activeTasks[taskId], var segment = active.segments[index] else { return }
            let dir = active.tempDirectory ?? segmentedTempDirectory(for: taskId)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let partURL = dir.appendingPathComponent("part-\(index).bin")

            do {
                if FileManager.default.fileExists(atPath: partURL.path) {
                    try FileManager.default.removeItem(at: partURL)
                }
                try FileManager.default.moveItem(at: location, to: partURL)
                segment.tempFileURL = partURL
                segment.bytesWritten = segment.range.upperBound - segment.range.lowerBound + 1
                segment.completed = true
                segment.urlTask = nil
                active.segments[index] = segment
                activeTasks[taskId] = active
                saveSegmentManifest(makeSegmentManifest(from: active))

                DispatchQueue.main.async {
                    self.scheduleNextSegmentChunks(for: taskId)
                    self.mergeSegmentsIfReady(taskId: taskId)
                }
            } catch {
                DispatchQueue.main.async {
                    self.handleFailure(taskId: taskId, error: error, resumeData: nil)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let descriptor = parseDescriptor(downloadTask.taskDescription) else { return }

        switch descriptor {
        case .single(let taskId):
            DispatchQueue.main.async {
                self.updateProgressAndSpeed(
                    taskId: taskId,
                    totalWritten: totalBytesWritten,
                    expectedTotal: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
                )
            }

        case .segment(let taskId, let index):
            DispatchQueue.main.async {
                guard var active = self.activeTasks[taskId], var segment = active.segments[index] else { return }
                segment.bytesWritten = totalBytesWritten
                active.segments[index] = segment
                self.activeTasks[taskId] = active

                let combinedWritten = active.segments.values.reduce(Int64(0)) { $0 + $1.bytesWritten }
                let combinedTotal = active.task.totalBytes > 0
                    ? active.task.totalBytes
                    : active.segments.values.reduce(Int64(0)) { $0 + ($1.range.upperBound - $1.range.lowerBound + 1) }

                self.updateProgressAndSpeed(
                    taskId: taskId,
                    totalWritten: combinedWritten,
                    expectedTotal: combinedTotal
                )
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let descriptor = parseDescriptor(downloadTask.taskDescription) else { return }

        guard let nsError = error as NSError? else { return }
        if nsError.code == NSURLErrorCancelled { return }

        switch descriptor {
        case .single(let taskId):
            DispatchQueue.main.async {
                let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                self.handleFailure(taskId: taskId, error: nsError, resumeData: resumeData)
            }

        case .segment(let taskId, _):
            DispatchQueue.main.async {
                guard let active = self.activeTasks[taskId] else { return }
                active.segments.values.forEach { $0.urlTask?.cancel() }
                self.handleFailure(taskId: taskId, error: nsError, resumeData: nil)
            }
        }
    }
}
