import Foundation
import Combine // ObservableObject, @Published

enum MCPTaskStatus: String, Codable {
    case pending
    case inProgress
    case paused
    case completed
    case failed
    case cancelled
}

enum MCPTaskType: String, Codable {
    case torrent
    case httpDownload
    case repair
}

struct MCPTask: Identifiable, Codable {
    let id: String
    let type: MCPTaskType
    var status: MCPTaskStatus
    var progress: Double
    var result: MCPTaskResult?
    var metadata: [String: String]
    
    enum MCPTaskResult: Codable {
        case success(files: [String])
        case failure(error: String)
    }
}

struct MCPTaskRequest: Codable {
    let taskId: String
    let taskType: MCPTaskType
    let source: String
    let destination: String
    let options: [String: String]?
}

struct MCPTaskResponse: Codable {
    let taskId: String
    let status: MCPTaskStatus
    let progress: Double
    let result: MCPTask.MCPTaskResult?
    let error: String?
}

protocol MCPTaskProvider {
    func startDownload(url: URL, destination: URL) -> UUID
    func pauseDownload(id: UUID)
    func resumeDownload(record: MCPResumeRecord) -> UUID?
    func repairDownload(id: UUID)
    func getPausedRecords() -> [MCPResumeRecord]
}

struct MCPResumeRecord: Codable {
    let id: UUID
    let url: URL
    let destination: URL
    let fileName: String
    let totalBytes: Int64
    let downloadedBytes: Int64
}

class MCPTaskManager: ObservableObject {
    static let shared = MCPTaskManager()
    
    @Published var activeTasks: [String: MCPTask] = [:]
    @Published var taskHistory: [MCPTask] = []
    
    var taskProvider: MCPTaskProvider?
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private var httpTaskMapping: [UUID: String] = [:]
    
    init() {
        loadTaskHistory()
    }
    
    func createTask(from request: MCPTaskRequest) -> String {
        let task = MCPTask(
            id: request.taskId,
            type: request.taskType,
            status: .pending,
            progress: 0,
            result: nil,
            metadata: [
                "source": request.source,
                "destination": request.destination,
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ]
        )
        
        activeTasks[request.taskId] = task
        
        processTask(task, request: request)
        
        return request.taskId
    }
    
    func getTaskStatus(taskId: String) -> MCPTaskResponse? {
        guard let task = activeTasks[taskId] else { return nil }
        
        return MCPTaskResponse(
            taskId: task.id,
            status: task.status,
            progress: task.progress,
            result: task.result,
            error: nil
        )
    }
    
    func pauseTask(taskId: String) {
        guard var task = activeTasks[taskId] else { return }
        
        task.status = .paused
        activeTasks[taskId] = task
        
        if let provider = taskProvider,
           let httpId = httpTaskMapping.first(where: { $0.value == taskId })?.key {
            provider.pauseDownload(id: httpId)
        }
    }
    
    func resumeTask(taskId: String) {
        guard var task = activeTasks[taskId] else { return }
        
        if let record = taskProvider?.getPausedRecords().first(where: { $0.id.uuidString == taskId }) {
            _ = taskProvider?.resumeDownload(record: record)
        }
        
        task.status = .inProgress
        activeTasks[taskId] = task
    }
    
    func cancelTask(taskId: String) {
        if let provider = taskProvider,
           let httpId = httpTaskMapping.first(where: { $0.value == taskId })?.key {
            provider.pauseDownload(id: httpId)
        }
        
        if var task = activeTasks[taskId] {
            task.status = .cancelled
            activeTasks[taskId] = task
            moveToHistory(task)
        }
    }
    
    func listTasks(status: MCPTaskStatus? = nil) -> [MCPTask] {
        if let status = status {
            return activeTasks.values.filter { $0.status == status }
        }
        return Array(activeTasks.values)
    }
    
    private func processTask(_ task: MCPTask, request: MCPTaskRequest) {
        var mutableTask = task
        mutableTask.status = .inProgress
        activeTasks[task.id] = mutableTask
        
        switch request.taskType {
        case .httpDownload:
            processHTTPDownload(taskId: task.id, request: request)
        case .torrent:
            processTorrent(taskId: task.id, request: request)
        case .repair:
            processRepair(taskId: task.id, request: request)
        }
    }
    
    private func processHTTPDownload(taskId: String, request: MCPTaskRequest) {
        guard let url = URL(string: request.source),
              let destination = URL(string: request.destination) else {
            failTask(taskId, error: "Invalid URL or destination")
            return
        }
        
        guard let provider = taskProvider else {
            failTask(taskId, error: "Task provider not configured")
            return
        }
        
        let downloadId = provider.startDownload(url: url, destination: destination)
        httpTaskMapping[downloadId] = taskId
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkDownloadProgress(taskId: taskId, provider: provider)
        }
    }
    
    private func checkDownloadProgress(taskId: String, provider: MCPTaskProvider?) {
        // This would be called to check progress - simplified for now
    }
    
    private func processTorrent(taskId: String, request: MCPTaskRequest) {
        // Torrent processing now runs through the in-app BitTorrent engine.
        // MCP requests still surface through the transfer center for execution.
        if var task = activeTasks[taskId] {
            task.status = .inProgress
            task.progress = 0
            activeTasks[taskId] = task
        }
    }
    
    private func processRepair(taskId: String, request: MCPTaskRequest) {
        guard let provider = taskProvider,
              let downloadId = UUID(uuidString: request.options?["downloadId"] ?? "") else {
            failTask(taskId, error: "Invalid repair request")
            return
        }
        
        provider.repairDownload(id: downloadId)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if var task = self?.activeTasks[taskId] {
                task.status = .completed
                task.result = .success(files: [request.destination])
                self?.activeTasks[taskId] = task
                self?.moveToHistory(task)
            }
        }
    }
    
    private func failTask(_ taskId: String, error: String) {
        guard var task = activeTasks[taskId] else { return }
        
        task.status = .failed
        task.result = .failure(error: error)
        activeTasks[taskId] = task
        
        moveToHistory(task)
    }
    
    private func moveToHistory(_ task: MCPTask) {
        activeTasks.removeValue(forKey: task.id)
        taskHistory.insert(task, at: 0)
        
        if taskHistory.count > 100 {
            taskHistory = Array(taskHistory.prefix(100))
        }
        
        saveTaskHistory()
    }
    
    private func saveTaskHistory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("neutron/mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("taskHistory.json")
        
        if let data = try? encoder.encode(taskHistory) {
            try? data.write(to: url)
        }
    }
    
    private func loadTaskHistory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("neutron/mcp/taskHistory.json")
        
        if let data = try? Data(contentsOf: url),
           let history = try? decoder.decode([MCPTask].self, from: data) {
            taskHistory = history
        }
    }
}

extension MCPTaskManager {
    func handleMCPRequest(_ data: Data) -> Data? {
        guard let request = try? decoder.decode(MCPTaskRequest.self, from: data) else {
            return nil
        }
        
        let taskId = createTask(from: request)
        
        guard let response = getTaskStatus(taskId: taskId) else {
            return nil
        }
        
        return try? encoder.encode(response)
    }
}
