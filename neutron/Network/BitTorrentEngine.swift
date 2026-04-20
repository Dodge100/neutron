import Combine
import Foundation
import Network

enum BitTorrentError: LocalizedError {
    case invalidTorrent
    case connectionFailed(String)
    case trackerError(String)
    case invalidResponse
    case pieceVerificationFailed(Int)
    case diskWriteFailed(String)
    case cancelled
    case unsupportedTracker(String)

    var errorDescription: String? {
        switch self {
        case .invalidTorrent:
            return "Invalid torrent file"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .trackerError(let msg):
            return "Tracker error: \(msg)"
        case .invalidResponse:
            return "Invalid response from peer"
        case .pieceVerificationFailed(let index):
            return "Piece \(index) verification failed"
        case .diskWriteFailed(let msg):
            return "Disk write failed: \(msg)"
        case .cancelled:
            return "Download cancelled"
        case .unsupportedTracker(let tracker):
            return "Unsupported tracker URL: \(tracker)"
        }
    }
}

struct PeerInfo: Hashable {
    let ip: String
    let port: UInt16
    let peerId: Data?
}

protocol BitTorrentEngineDelegate: AnyObject {
    func engine(_ engine: BitTorrentEngine, didUpdateProgress progress: Double, downloaded: Int64, total: Int64)
    func engine(_ engine: BitTorrentEngine, didCompletePiece index: Int)
    func engine(_ engine: BitTorrentEngine, didFinishDownloading files: [URL])
    func engine(_ engine: BitTorrentEngine, didEncounterError error: Error)
    func engine(_ engine: BitTorrentEngine, didUpdatePeers peers: [PeerInfo])
    func engine(_ engine: BitTorrentEngine, didUpdateStats stats: TorrentStats)
}

struct TorrentStats {
    var peersConnected: Int
    var peersAvailable: Int
    var downloadSpeed: Double
    var uploadSpeed: Double
    var uploaded: Int64
    var downloaded: Int64
    var seeders: Int
    var leechers: Int
}

final class BitTorrentEngine: ObservableObject {
    enum TorrentState: Equatable {
        case connecting
        case downloading
        case paused
        case completed
        case error(String)
    }

    weak var delegate: BitTorrentEngineDelegate?

    private let torrent: TorrentFile
    private let outputDirectory: URL
    private let peerId: Data
    private let queue = DispatchQueue(label: "com.neutron.bittorrent", qos: .userInitiated)
    private let maxConnections = 24

    @Published var state: TorrentState = .connecting
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var peers: [PeerInfo] = []
    @Published var stats = TorrentStats(peersConnected: 0, peersAvailable: 0, downloadSpeed: 0, uploadSpeed: 0, uploaded: 0, downloaded: 0, seeders: 0, leechers: 0)

    private var completedPieces: Set<Int> = []
    private var pieceData: [Int: Data] = [:]
    private var pendingPieces: [Int] = []
    private var assignedPieces: [Int: String] = [:]
    private var connections: [String: PeerConnection] = [:]
    private var cancelled = false
    private var statsTask: Task<Void, Never>?
    private var lastStatsTimestamp = Date()
    private var lastStatsDownloaded: Int64 = 0

    init(torrent: TorrentFile, outputDirectory: URL, peerId: Data = BitTorrentPeerID.generate()) {
        self.torrent = torrent
        self.outputDirectory = outputDirectory
        self.totalBytes = torrent.length
        self.peerId = peerId
        self.pendingPieces = Array(0..<torrent.pieceCount)
    }

    func start(initialPeers: [PeerInfo] = []) {
        cancelled = false
        pendingPieces = Array((0..<torrent.pieceCount).filter { !completedPieces.contains($0) })
        updateState(.connecting)

        Task {
            do {
                var discoveredPeers = deduplicatedPeers(initialPeers)

                do {
                    let trackerResult = try await announceToTracker()
                    discoveredPeers = deduplicatedPeers(discoveredPeers + trackerResult.peers)
                    await MainActor.run {
                        self.stats.seeders = trackerResult.complete
                        self.stats.leechers = trackerResult.incomplete
                    }
                } catch {
                    if discoveredPeers.isEmpty {
                        throw error
                    }
                }

                guard !discoveredPeers.isEmpty else {
                    throw BitTorrentError.connectionFailed("No peers were returned by the available trackers or DHT")
                }

                await MainActor.run {
                    self.peers = discoveredPeers
                    self.stats.peersAvailable = discoveredPeers.count
                    self.delegate?.engine(self, didUpdatePeers: discoveredPeers)
                    self.delegate?.engine(self, didUpdateStats: self.stats)
                }
                connectToPeers(discoveredPeers)
                startStatsLoop()
                updateState(.downloading)
            } catch {
                report(error: error)
            }
        }
    }

    func pause() {
        cancelled = false
        stopStatsLoop()
        queue.async {
            self.connections.values.forEach { $0.disconnect() }
            self.connections.removeAll()
            self.assignedPieces.removeAll()
            self.rebuildPendingQueue()
            self.publishStats()
        }
        updateState(.paused)
    }

    func resume() {
        start()
    }

    func cancel() {
        cancelled = true
        stopStatsLoop()
        queue.async {
            self.connections.values.forEach { $0.disconnect() }
            self.connections.removeAll()
            self.assignedPieces.removeAll()
            self.publishStats()
        }
        updateState(.error("Cancelled"))
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    func getDownloadedPieces() -> Set<Int> {
        completedPieces
    }

    func getPieceData(_ index: Int) -> Data? {
        pieceData[index]
    }

    private func announceToTracker() async throws -> TrackerAnnounceResult {
        try await TrackerClient.announce(
            announce: torrent.announce,
            announceList: torrent.announceList,
            infoHash: torrent.infoHash,
            peerId: peerId,
            downloaded: downloadedBytes,
            left: max(totalBytes - downloadedBytes, 0),
            event: .started
        )
    }

    private func connectToPeers(_ peers: [PeerInfo]) {
        queue.async {
            for peer in peers.prefix(self.maxConnections) {
                let connection = PeerConnection(peer: peer, torrent: self.torrent, peerId: self.peerId)
                connection.delegate = self
                self.connections[connection.peerKey] = connection
                connection.connect()
            }
            self.publishStats()
        }
    }

    private func assignNextPiece(to connection: PeerConnection) {
        guard !cancelled else { return }
        guard case .downloading = state else { return }
        guard connection.isReadyForRequests else { return }
        guard connection.currentPieceIndex == nil else { return }

        if let nextPiece = pendingPieces.first(where: { !assignedPieces.keys.contains($0) && connection.canDownload(piece: $0) }) {
            pendingPieces.removeAll { $0 == nextPiece }
            assignedPieces[nextPiece] = connection.peerKey
            connection.startPiece(index: nextPiece, length: expectedPieceLength(for: nextPiece))
        }
    }

    private func expectedPieceLength(for index: Int) -> Int {
        if index == torrent.pieceCount - 1 {
            let remainder = Int(torrent.length % torrent.pieceLength)
            return remainder == 0 ? Int(torrent.pieceLength) : remainder
        }
        return Int(torrent.pieceLength)
    }

    private func markPieceComplete(_ index: Int, data: Data, from connection: PeerConnection) {
        let hashStart = index * 20
        let hashEnd = hashStart + 20
        guard hashEnd <= torrent.pieces.count else {
            report(error: BitTorrentError.pieceVerificationFailed(index))
            return
        }

        let expectedHash = Data(torrent.pieces[hashStart..<hashEnd])
        guard let actualHash = CryptoUtils.sha1(data), actualHash == expectedHash else {
            assignedPieces.removeValue(forKey: index)
            if !completedPieces.contains(index) {
                pendingPieces.append(index)
            }
            delegate?.engine(self, didEncounterError: BitTorrentError.pieceVerificationFailed(index))
            assignNextPiece(to: connection)
            return
        }

        completedPieces.insert(index)
        pieceData[index] = data
        assignedPieces.removeValue(forKey: index)

        Task { @MainActor in
            self.downloadedBytes += Int64(data.count)
            self.stats.downloaded = self.downloadedBytes
            self.delegate?.engine(self, didCompletePiece: index)
            self.delegate?.engine(self, didUpdateProgress: self.progress, downloaded: self.downloadedBytes, total: self.totalBytes)
            self.delegate?.engine(self, didUpdateStats: self.stats)
        }

        if completedPieces.count == torrent.pieceCount {
            do {
                try writePiecesToDisk()
                stopStatsLoop()
                updateState(.completed)
                let files = torrent.files.map { outputDirectory.appendingPathComponent($0.path) }
                Task { @MainActor in
                    self.delegate?.engine(self, didFinishDownloading: files)
                }
            } catch {
                report(error: error)
            }
        } else {
            assignNextPiece(to: connection)
        }
    }

    private func rebuildPendingQueue() {
        let remaining = Set(0..<torrent.pieceCount)
            .subtracting(completedPieces)
            .subtracting(Set(assignedPieces.keys))
        pendingPieces = Array(remaining).sorted()
    }

    private func publishStats() {
        Task { @MainActor in
            self.stats.peersConnected = self.connections.values.filter(\.isConnected).count
            self.stats.peersAvailable = self.peers.count
            self.delegate?.engine(self, didUpdateStats: self.stats)
        }
    }

    private func startStatsLoop() {
        stopStatsLoop()
        lastStatsTimestamp = Date()
        lastStatsDownloaded = downloadedBytes

        statsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.cancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let now = Date()
                let interval = now.timeIntervalSince(self.lastStatsTimestamp)
                guard interval > 0 else { continue }
                let delta = self.downloadedBytes - self.lastStatsDownloaded
                self.lastStatsTimestamp = now
                self.lastStatsDownloaded = self.downloadedBytes

                self.stats.downloadSpeed = Double(delta) / interval
                self.stats.downloaded = self.downloadedBytes
                self.delegate?.engine(self, didUpdateStats: self.stats)
            }
        }
    }

    private func stopStatsLoop() {
        statsTask?.cancel()
        statsTask = nil
    }

    private func writePiecesToDisk() throws {
        if torrent.isMultiFile {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for entry in torrent.files {
                let filePath = outputDirectory.appendingPathComponent(entry.path)
                try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
        }

        var offset: Int64 = 0
        for entry in torrent.files {
            let filePath = outputDirectory.appendingPathComponent(entry.path)
            var fileContents = Data()
            var remaining = entry.length

            while remaining > 0 {
                let pieceIndex = Int(offset / torrent.pieceLength)
                let pieceOffset = Int(offset % torrent.pieceLength)
                let bytesToCopy = min(remaining, torrent.pieceLength - Int64(pieceOffset))

                guard let piece = pieceData[pieceIndex] else {
                    throw BitTorrentError.diskWriteFailed("Missing piece \(pieceIndex) while writing \(entry.path)")
                }

                let start = pieceOffset
                let end = min(piece.count, pieceOffset + Int(bytesToCopy))
                fileContents.append(piece[start..<end])
                offset += Int64(end - start)
                remaining -= Int64(end - start)
            }

            try fileContents.write(to: filePath)
        }
    }

    private func updateState(_ newState: TorrentState) {
        Task { @MainActor in
            self.state = newState
        }
    }

    private func deduplicatedPeers(_ peers: [PeerInfo]) -> [PeerInfo] {
        var seen = Set<PeerInfo>()
        return peers.filter { seen.insert($0).inserted }
    }

    private func report(error: Error) {
        stopStatsLoop()
        updateState(.error(error.localizedDescription))
        Task { @MainActor in
            self.delegate?.engine(self, didEncounterError: error)
        }
    }
}

private protocol PeerConnectionDelegate: AnyObject {
    func connectionDidBecomeReadyForRequests(_ connection: PeerConnection)
    func connection(_ connection: PeerConnection, didCompletePiece index: Int, data: Data)
    func connection(_ connection: PeerConnection, didDisconnect peerKey: String)
}

private final class PeerConnection {
    weak var delegate: PeerConnectionDelegate?

    let peer: PeerInfo
    let peerKey: String
    private let torrent: TorrentFile
    private let peerId: Data
    private let queue: DispatchQueue
    private let blockSize = 16 * 1024
    private let maxInFlightRequests = 4

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var handshakeReceived = false
    private var interestedSent = false
    private var peerIsChoking = true
    private var availablePieces = Set<Int>()
    private(set) var currentPieceIndex: Int?
    private var currentPieceLength = 0
    private var pendingOffsets: [Int] = []
    private var inflightOffsets: Set<Int> = []
    private var receivedBlocks: [Int: Data] = [:]

    private(set) var isConnected = false

    var isReadyForRequests: Bool {
        isConnected && handshakeReceived && interestedSent && !peerIsChoking
    }

    init(peer: PeerInfo, torrent: TorrentFile, peerId: Data) {
        self.peer = peer
        self.peerKey = "\(peer.ip):\(peer.port)"
        self.torrent = torrent
        self.peerId = peerId
        self.queue = DispatchQueue(label: "com.neutron.bittorrent.peer.\(peer.ip).\(peer.port)")
    }

    func connect() {
        guard let port = NWEndpoint.Port(rawValue: peer.port) else {
            delegate?.connection(self, didDisconnect: peerKey)
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(peer.ip), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.sendHandshake()
                self.receive()
            case .failed, .cancelled:
                self.disconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        delegate?.connection(self, didDisconnect: peerKey)
    }

    func canDownload(piece index: Int) -> Bool {
        availablePieces.contains(index)
    }

    func startPiece(index: Int, length: Int) {
        guard isReadyForRequests else { return }
        currentPieceIndex = index
        currentPieceLength = length
        pendingOffsets = stride(from: 0, to: length, by: blockSize).map { $0 }
        inflightOffsets.removeAll()
        receivedBlocks.removeAll()
        requestMoreBlocks()
    }

    private func sendHandshake() {
        var payload = Data()
        payload.append(0x13)
        payload.append(Data("BitTorrent protocol".utf8))
        payload.append(Data(repeating: 0, count: 8))
        payload.append(torrent.infoHash)
        payload.append(peerId)
        connection?.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func sendInterestedIfNeeded() {
        guard !interestedSent else { return }
        interestedSent = true
        sendMessage(id: 2, payload: Data())
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if isComplete || error != nil {
                self.disconnect()
                return
            }

            self.receive()
        }
    }

    private func processReceiveBuffer() {
        if !handshakeReceived {
            guard receiveBuffer.count >= 68 else { return }
            let handshake = receiveBuffer.prefix(68)
            guard handshake.first == 19,
                  Data(handshake[1..<20]) == Data("BitTorrent protocol".utf8),
                  Data(handshake[28..<48]) == torrent.infoHash else {
                disconnect()
                return
            }
            receiveBuffer.removeFirst(68)
            handshakeReceived = true
            sendInterestedIfNeeded()
        }

        while receiveBuffer.count >= 4 {
            let length = Int(UInt32(bigEndianBytes: receiveBuffer.prefix(4)))
            if length == 0 {
                receiveBuffer.removeFirst(4)
                continue
            }

            guard receiveBuffer.count >= 4 + length else { return }
            let message = receiveBuffer.subdata(in: 4..<(4 + length))
            receiveBuffer.removeFirst(4 + length)
            handleMessage(message)
        }
    }

    private func handleMessage(_ message: Data) {
        guard let messageID = message.first else { return }
        let payload = message.dropFirst()

        switch messageID {
        case 0:
            peerIsChoking = true
        case 1:
            peerIsChoking = false
            delegate?.connectionDidBecomeReadyForRequests(self)
            requestMoreBlocks()
        case 4:
            guard payload.count >= 4 else { return }
            let pieceIndex = Int(UInt32(bigEndianBytes: payload.prefix(4)))
            availablePieces.insert(pieceIndex)
            delegate?.connectionDidBecomeReadyForRequests(self)
        case 5:
            availablePieces = parseBitfield(Data(payload), pieceCount: torrent.pieceCount)
            delegate?.connectionDidBecomeReadyForRequests(self)
        case 7:
            guard payload.count >= 8 else { return }
            let pieceIndex = Int(UInt32(bigEndianBytes: payload.prefix(4)))
            let begin = Int(UInt32(bigEndianBytes: payload.dropFirst(4).prefix(4)))
            let block = Data(payload.dropFirst(8))
            handlePieceBlock(pieceIndex: pieceIndex, offset: begin, data: block)
        default:
            break
        }
    }

    private func handlePieceBlock(pieceIndex: Int, offset: Int, data: Data) {
        guard currentPieceIndex == pieceIndex else { return }
        inflightOffsets.remove(offset)
        receivedBlocks[offset] = data
        requestMoreBlocks()

        let bytesReceived = receivedBlocks.values.reduce(0) { $0 + $1.count }
        guard bytesReceived >= currentPieceLength else { return }

        var piece = Data(capacity: currentPieceLength)
        for offset in receivedBlocks.keys.sorted() {
            if let block = receivedBlocks[offset] {
                piece.append(block)
            }
        }
        piece = piece.prefix(currentPieceLength)

        resetCurrentPiece()
        delegate?.connection(self, didCompletePiece: pieceIndex, data: piece)
    }

    private func requestMoreBlocks() {
        guard isReadyForRequests, let currentPieceIndex else { return }

        while inflightOffsets.count < maxInFlightRequests, let offset = pendingOffsets.first {
            pendingOffsets.removeFirst()
            inflightOffsets.insert(offset)
            let length = min(blockSize, currentPieceLength - offset)
            sendRequest(pieceIndex: currentPieceIndex, offset: offset, length: length)
        }
    }

    private func sendRequest(pieceIndex: Int, offset: Int, length: Int) {
        var payload = Data()
        payload.append(UInt32(pieceIndex).bigEndianData)
        payload.append(UInt32(offset).bigEndianData)
        payload.append(UInt32(length).bigEndianData)
        sendMessage(id: 6, payload: payload)
    }

    private func sendMessage(id: UInt8, payload: Data) {
        var message = Data()
        let length = UInt32(payload.count + 1)
        message.append(length.bigEndianData)
        message.append(id)
        message.append(payload)
        connection?.send(content: message, completion: .contentProcessed { _ in })
    }

    private func resetCurrentPiece() {
        currentPieceIndex = nil
        currentPieceLength = 0
        pendingOffsets.removeAll()
        inflightOffsets.removeAll()
        receivedBlocks.removeAll()
    }

    private func parseBitfield(_ data: Data, pieceCount: Int) -> Set<Int> {
        var pieces = Set<Int>()
        for (byteIndex, byte) in data.enumerated() {
            for bit in 0..<8 {
                let pieceIndex = byteIndex * 8 + bit
                guard pieceIndex < pieceCount else { break }
                if byte & (1 << (7 - bit)) != 0 {
                    pieces.insert(pieceIndex)
                }
            }
        }
        return pieces
    }
}

extension BitTorrentEngine: PeerConnectionDelegate {
    fileprivate func connectionDidBecomeReadyForRequests(_ connection: PeerConnection) {
        queue.async {
            self.assignNextPiece(to: connection)
        }
    }

    fileprivate func connection(_ connection: PeerConnection, didCompletePiece index: Int, data: Data) {
        queue.async {
            self.markPieceComplete(index, data: data, from: connection)
        }
    }

    fileprivate func connection(_ connection: PeerConnection, didDisconnect peerKey: String) {
        queue.async {
            if let pieceIndex = connection.currentPieceIndex {
                self.assignedPieces.removeValue(forKey: pieceIndex)
                if !self.completedPieces.contains(pieceIndex) {
                    self.pendingPieces.append(pieceIndex)
                }
            }
            self.connections.removeValue(forKey: peerKey)
            self.publishStats()
        }
    }
}

private extension UInt32 {
    init(bigEndianBytes data: Data.SubSequence) {
        self = data.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    var bigEndianData: Data {
        withUnsafeBytes(of: self.bigEndian) { Data($0) }
    }
}
