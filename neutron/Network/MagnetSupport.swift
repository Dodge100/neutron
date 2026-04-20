import Foundation
import Network

enum BitTorrentPeerID {
    static func generate() -> Data {
        var data = Data("-NE0001-".utf8)
        for _ in 0..<12 {
            data.append(UInt8.random(in: 0...255))
        }
        return data
    }
}

enum MagnetError: LocalizedError {
    case invalidLink
    case missingInfoHash
    case unsupportedInfoHash
    case noPeers
    case metadataUnavailable
    case invalidMetadata
    case metadataTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "Invalid magnet link"
        case .missingInfoHash:
            return "Magnet link is missing a BitTorrent info hash"
        case .unsupportedInfoHash:
            return "Magnet link uses an unsupported info hash format"
        case .noPeers:
            return "No peers were found for this magnet link"
        case .metadataUnavailable:
            return "Unable to fetch torrent metadata from the discovered peers"
        case .invalidMetadata:
            return "The magnet metadata response was invalid"
        case .metadataTooLarge(let size):
            return "Magnet metadata is unexpectedly large (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        }
    }
}

struct MagnetLink {
    let infoHash: Data
    let trackers: [URL]
    let displayName: String?
    let exactPeers: [PeerInfo]

    init(urlString: String) throws {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "magnet" else {
            throw MagnetError.invalidLink
        }

        let items = components.queryItems ?? []

        guard let xtValue = items
            .first(where: { $0.name.caseInsensitiveCompare("xt") == .orderedSame })?
            .value else {
            throw MagnetError.missingInfoHash
        }

        guard let infoHash = Self.parseInfoHash(xtValue) else {
            throw MagnetError.unsupportedInfoHash
        }

        self.infoHash = infoHash
        self.displayName = items
            .first(where: { $0.name.caseInsensitiveCompare("dn") == .orderedSame })?
            .value?
            .removingPercentEncoding

        var seenTrackers = Set<String>()
        self.trackers = items
            .filter { $0.name.caseInsensitiveCompare("tr") == .orderedSame }
            .compactMap(\.value)
            .compactMap { rawValue in
                let decoded = rawValue.removingPercentEncoding ?? rawValue
                guard let url = URL(string: decoded),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "udp"].contains(scheme) else {
                    return nil
                }
                let key = url.absoluteString.lowercased()
                guard seenTrackers.insert(key).inserted else { return nil }
                return url
            }

        var seenPeers = Set<String>()
        self.exactPeers = items
            .filter { $0.name.caseInsensitiveCompare("x.pe") == .orderedSame }
            .compactMap(\.value)
            .compactMap { PeerInfo(exactPeerValue: $0) }
            .filter { peer in
                let key = "\(peer.ip):\(peer.port)"
                return seenPeers.insert(key).inserted
            }
    }

    private static func parseInfoHash(_ value: String) -> Data? {
        let lowercasedValue = value.lowercased()
        guard let hashRange = lowercasedValue.range(of: "urn:btih:") else { return nil }
        let rawHash = String(value[hashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        if rawHash.count == 40 {
            return Data(hexString: rawHash)
        }
        if rawHash.count == 32 {
            return Data(base32Encoded: rawHash)
        }
        return nil
    }
}

struct TrackerAnnounceResult {
    let peers: [PeerInfo]
    let complete: Int
    let incomplete: Int
}

enum TrackerEvent {
    case started

    var httpValue: String {
        switch self {
        case .started:
            return "started"
        }
    }

    var udpValue: UInt32 {
        switch self {
        case .started:
            return 2
        }
    }
}

enum TrackerClient {
    static func announce(
        announce: String?,
        announceList: [String],
        infoHash: Data,
        peerId: Data,
        port: UInt16 = 6881,
        downloaded: Int64,
        left: Int64,
        event: TrackerEvent
    ) async throws -> TrackerAnnounceResult {
        let trackers = trackerURLs(announce: announce, announceList: announceList)
        guard !trackers.isEmpty else {
            throw BitTorrentError.unsupportedTracker("No supported tracker URL was found")
        }

        var successes: [TrackerAnnounceResult] = []
        var lastError: Error?

        await withTaskGroup(of: Result<TrackerAnnounceResult, Error>.self) { group in
            for tracker in trackers {
                group.addTask {
                    do {
                        return .success(try await TrackerClient.announce(
                            to: tracker,
                            infoHash: infoHash,
                            peerId: peerId,
                            port: port,
                            downloaded: downloaded,
                            left: left,
                            event: event
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let announceResult):
                    successes.append(announceResult)
                case .failure(let error):
                    lastError = error
                }
            }
        }

        guard !successes.isEmpty else {
            throw lastError ?? BitTorrentError.trackerError("Tracker announce failed")
        }

        var seenPeers = Set<PeerInfo>()
        let peers = successes
            .flatMap(\.peers)
            .filter { seenPeers.insert($0).inserted }

        return TrackerAnnounceResult(
            peers: peers,
            complete: successes.map(\.complete).max() ?? 0,
            incomplete: successes.map(\.incomplete).max() ?? 0
        )
    }

    private static func trackerURLs(announce: String?, announceList: [String]) -> [URL] {
        var seen = Set<String>()
        return (announceList + [announce].compactMap { $0 })
            .compactMap(URL.init(string:))
            .filter { url in
                guard let scheme = url.scheme?.lowercased(), ["http", "https", "udp"].contains(scheme) else {
                    return false
                }
                return seen.insert(url.absoluteString.lowercased()).inserted
            }
    }

    private static func announce(
        to tracker: URL,
        infoHash: Data,
        peerId: Data,
        port: UInt16,
        downloaded: Int64,
        left: Int64,
        event: TrackerEvent
    ) async throws -> TrackerAnnounceResult {
        guard let scheme = tracker.scheme?.lowercased() else {
            throw BitTorrentError.unsupportedTracker(tracker.absoluteString)
        }

        switch scheme {
        case "http", "https":
            return try await announceHTTP(
                to: tracker,
                infoHash: infoHash,
                peerId: peerId,
                port: port,
                downloaded: downloaded,
                left: left,
                event: event
            )
        case "udp":
            return try await announceUDP(
                to: tracker,
                infoHash: infoHash,
                peerId: peerId,
                port: port,
                downloaded: downloaded,
                left: left,
                event: event
            )
        default:
            throw BitTorrentError.unsupportedTracker(tracker.absoluteString)
        }
    }

    private static func announceHTTP(
        to tracker: URL,
        infoHash: Data,
        peerId: Data,
        port: UInt16,
        downloaded: Int64,
        left: Int64,
        event: TrackerEvent
    ) async throws -> TrackerAnnounceResult {
        var components = URLComponents(url: tracker, resolvingAgainstBaseURL: false)
        let existingQuery = components?.percentEncodedQuery.map { $0 + "&" } ?? ""
        let trackerQuery = [
            "info_hash=\(percentEncodedBinary(infoHash))",
            "peer_id=\(percentEncodedBinary(peerId))",
            "port=\(port)",
            "uploaded=0",
            "downloaded=\(max(downloaded, 0))",
            "left=\(max(left, 0))",
            "compact=1",
            "event=\(event.httpValue)",
        ].joined(separator: "&")
        components?.percentEncodedQuery = existingQuery + trackerQuery

        guard let url = components?.url else {
            throw BitTorrentError.trackerError("Failed to build tracker URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BitTorrentError.trackerError("Tracker request failed")
        }

        guard let payload = Bencode.decode(data), let dict = payload.dict else {
            throw BitTorrentError.invalidResponse
        }
        if let failure = dict["failure reason"]?.string {
            throw BitTorrentError.trackerError(failure)
        }

        return TrackerAnnounceResult(
            peers: parsePeers(from: dict["peers"]),
            complete: dict["complete"]?.int ?? 0,
            incomplete: dict["incomplete"]?.int ?? 0
        )
    }

    private static func announceUDP(
        to tracker: URL,
        infoHash: Data,
        peerId: Data,
        port: UInt16,
        downloaded: Int64,
        left: Int64,
        event: TrackerEvent
    ) async throws -> TrackerAnnounceResult {
        guard let host = tracker.host,
              let portNumber = UInt16(exactly: tracker.port ?? 80) else {
            throw BitTorrentError.unsupportedTracker(tracker.absoluteString)
        }

        let connectTransactionID = UInt32.random(in: .min ... .max)
        var connectRequest = Data()
        connectRequest.append(bigEndianBytes(UInt64(0x41727101980)))
        connectRequest.append(bigEndianBytes(UInt32(0)))
        connectRequest.append(bigEndianBytes(connectTransactionID))

        guard let connectResponse = await UDPDatagramClient.send(connectRequest, host: host, port: portNumber),
              let connectAction = readUInt32(connectResponse, at: 0),
              let returnedTransactionID = readUInt32(connectResponse, at: 4),
              connectAction == 0,
              returnedTransactionID == connectTransactionID,
              let connectionID = readUInt64(connectResponse, at: 8) else {
            throw BitTorrentError.trackerError("UDP tracker connection failed")
        }

        let announceTransactionID = UInt32.random(in: .min ... .max)
        var announceRequest = Data()
        announceRequest.append(bigEndianBytes(connectionID))
        announceRequest.append(bigEndianBytes(UInt32(1)))
        announceRequest.append(bigEndianBytes(announceTransactionID))
        announceRequest.append(infoHash)
        announceRequest.append(peerId)
        announceRequest.append(bigEndianBytes(UInt64(max(downloaded, 0))))
        announceRequest.append(bigEndianBytes(UInt64(max(left, 0))))
        announceRequest.append(bigEndianBytes(UInt64(0)))
        announceRequest.append(bigEndianBytes(event.udpValue))
        announceRequest.append(bigEndianBytes(UInt32(0)))
        announceRequest.append(bigEndianBytes(UInt32.random(in: .min ... .max)))
        announceRequest.append(bigEndianBytes(UInt32(bitPattern: -1)))
        announceRequest.append(bigEndianBytes(port))

        guard let announceResponse = await UDPDatagramClient.send(announceRequest, host: host, port: portNumber),
              let announceAction = readUInt32(announceResponse, at: 0),
              let responseTransactionID = readUInt32(announceResponse, at: 4),
              announceAction == 1,
              responseTransactionID == announceTransactionID else {
            throw BitTorrentError.trackerError("UDP tracker announce failed")
        }

        let incomplete = Int(readUInt32(announceResponse, at: 12) ?? 0)
        let complete = Int(readUInt32(announceResponse, at: 16) ?? 0)
        let peerData = announceResponse.count > 20 ? announceResponse.subdata(in: 20..<announceResponse.count) : Data()

        return TrackerAnnounceResult(
            peers: parseCompactPeers(peerData),
            complete: complete,
            incomplete: incomplete
        )
    }

    private static func parsePeers(from value: BencodeValue?) -> [PeerInfo] {
        if let peerData = value?.data {
            return parseCompactPeers(peerData)
        }

        guard let peerList = value?.list else { return [] }
        return peerList.compactMap { entry in
            guard let dict = entry.dict,
                  let ip = dict["ip"]?.string,
                  let port = dict["port"]?.int else {
                return nil
            }
            return PeerInfo(ip: ip, port: UInt16(port), peerId: dict["peer id"]?.data)
        }
    }
}

enum DHTClient {
    private static let bootstrapNodes: [DHTNode] = [
        DHTNode(host: "router.bittorrent.com", port: 6881),
        DHTNode(host: "dht.transmissionbt.com", port: 6881),
        DHTNode(host: "router.utorrent.com", port: 6881),
    ]

    static func getPeers(infoHash: Data, maxPeers: Int = 48) async -> [PeerInfo] {
        var frontier = bootstrapNodes
        var visited = Set<String>()
        var foundPeers = Set<PeerInfo>()

        for _ in 0..<3 {
            let batch = frontier.filter { visited.insert($0.key).inserted }
            if batch.isEmpty { break }

            let limitedBatch = Array(batch.prefix(24))
            let responses = await queryNodes(limitedBatch, infoHash: infoHash)
            frontier = []

            for response in responses {
                for peer in response.peers {
                    foundPeers.insert(peer)
                    if foundPeers.count >= maxPeers {
                        return Array(foundPeers)
                    }
                }

                for node in response.nodes where !visited.contains(node.key) {
                    frontier.append(node)
                }
            }
        }

        return Array(foundPeers)
    }

    private static func queryNodes(_ nodes: [DHTNode], infoHash: Data) async -> [DHTResponse] {
        await withTaskGroup(of: DHTResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    await queryGetPeers(node: node, infoHash: infoHash)
                }
            }

            var responses: [DHTResponse] = []
            for await response in group {
                if let response {
                    responses.append(response)
                }
            }
            return responses
        }
    }

    private static func queryGetPeers(node: DHTNode, infoHash: Data) async -> DHTResponse? {
        let transactionID = Data((0..<2).map { _ in UInt8.random(in: 0...255) })
        let nodeID = Data(infoHash.prefix(10)) + Data((0..<10).map { _ in UInt8.random(in: 0...255) })

        let query = BencodeValue.dict([
            "a": .dict([
                "id": .string(nodeID),
                "info_hash": .string(infoHash),
            ]),
            "q": .string(Data("get_peers".utf8)),
            "t": .string(transactionID),
            "y": .string(Data("q".utf8)),
        ])

        guard let encodedQuery = try? BencodeEncoder.encode(query),
              let payload = await UDPDatagramClient.send(encodedQuery, host: node.host, port: node.port),
              let dict = Bencode.decode(payload)?.dict,
              dict["y"]?.string != "e",
              let responseDict = dict["r"]?.dict else {
            return nil
        }

        let peers = responseDict["values"]?.list?
            .compactMap(\.data)
            .flatMap(parseCompactPeers) ?? []
        let nodes = responseDict["nodes"]?.data.map(parseCompactNodes) ?? []
        return DHTResponse(peers: peers, nodes: nodes)
    }
}

struct ResolvedMagnet {
    let torrent: TorrentFile
    let peerId: Data
    let initialPeers: [PeerInfo]
}

final class MagnetMetadataResolver {
    private let magnet: MagnetLink
    private let peerId: Data
    private let onUpdate: ((Double, String) -> Void)?

    init(magnet: MagnetLink, peerId: Data = BitTorrentPeerID.generate(), onUpdate: ((Double, String) -> Void)? = nil) {
        self.magnet = magnet
        self.peerId = peerId
        self.onUpdate = onUpdate
    }

    func resolve() async throws -> ResolvedMagnet {
        report(progress: 0.01, status: "Resolving magnet peers...")

        async let trackerPeersTask: [PeerInfo] = {
            guard !self.magnet.trackers.isEmpty else { return [] }
            let result = try? await TrackerClient.announce(
                announce: self.magnet.trackers.first?.absoluteString,
                announceList: self.magnet.trackers.dropFirst().map(\.absoluteString),
                infoHash: self.magnet.infoHash,
                peerId: self.peerId,
                downloaded: 0,
                left: 1,
                event: .started
            )
            return result?.peers ?? []
        }()

        async let dhtPeersTask = DHTClient.getPeers(infoHash: magnet.infoHash)

        let trackerPeers = await trackerPeersTask
        if !trackerPeers.isEmpty {
            report(progress: 0.03, status: "Found \(trackerPeers.count) tracker peers")
        }

        let dhtPeers = await dhtPeersTask
        if !dhtPeers.isEmpty {
            report(progress: 0.05, status: "Found \(dhtPeers.count) DHT peers")
        }

        let peers = deduplicatedPeers(magnet.exactPeers + trackerPeers + dhtPeers)
        guard !peers.isEmpty else {
            throw MagnetError.noPeers
        }

        report(progress: 0.06, status: "Fetching torrent metadata from \(peers.count) peers...")
        guard let metadata = await fetchMetadata(from: peers) else {
            throw MagnetError.metadataUnavailable
        }

        report(progress: 0.08, status: "Verified magnet metadata")

        guard let torrent = TorrentFile(
            infoDictionaryData: metadata,
            announce: magnet.trackers.first?.absoluteString,
            announceList: magnet.trackers.dropFirst().map(\.absoluteString),
            expectedInfoHash: magnet.infoHash
        ) else {
            throw MagnetError.invalidMetadata
        }

        return ResolvedMagnet(torrent: torrent, peerId: peerId, initialPeers: peers)
    }

    private func fetchMetadata(from peers: [PeerInfo]) async -> Data? {
        let maxConcurrentSessions = min(6, peers.count)
        var iterator = peers.makeIterator()

        return await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<maxConcurrentSessions {
                guard let peer = iterator.next() else { break }
                group.addTask {
                    let session = await MetadataPeerSession(peer: peer, infoHash: self.magnet.infoHash, peerId: self.peerId) { progress, status in
                        self.report(progress: 0.06 + (progress * 0.02), status: status)
                    }
                    return await session.fetchMetadata()
                }
            }

            while let metadata = await group.next() {
                if let metadata {
                    group.cancelAll()
                    return metadata
                }

                if let peer = iterator.next() {
                    group.addTask {
                        let session = await MetadataPeerSession(peer: peer, infoHash: self.magnet.infoHash, peerId: self.peerId) { progress, status in
                            self.report(progress: 0.06 + (progress * 0.02), status: status)
                        }
                        return await session.fetchMetadata()
                    }
                }
            }

            return nil
        }
    }

    private func report(progress: Double, status: String) {
        onUpdate?(progress, status)
    }

    private func deduplicatedPeers(_ peers: [PeerInfo]) -> [PeerInfo] {
        var seen = Set<PeerInfo>()
        return peers.filter { seen.insert($0).inserted }
    }
}

private struct DHTNode: Hashable {
    let host: String
    let port: UInt16

    var key: String {
        "\(host):\(port)"
    }
}

private struct DHTResponse {
    let peers: [PeerInfo]
    let nodes: [DHTNode]
}

private final class MetadataPeerSession {
    private let peer: PeerInfo
    private let infoHash: Data
    private let peerId: Data
    private let onUpdate: ((Double, String) -> Void)?
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var hasFinished = false
    private var receiveBuffer = Data()
    private var receivedHandshake = false
    private var peerSupportsExtensions = false
    private var metadataMessageID: UInt8?
    private var metadataSize = 0
    private var metadataPieces: [Int: Data] = [:]
    private var requestedPieces = Set<Int>()
    private var maxRequestedPiece = -1

    init(peer: PeerInfo, infoHash: Data, peerId: Data, onUpdate: ((Double, String) -> Void)? = nil) {
        self.peer = peer
        self.infoHash = infoHash
        self.peerId = peerId
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "com.neutron.bittorrent.metadata.\(peer.ip).\(peer.port)")
    }

    func fetchMetadata(timeout: TimeInterval = 12) async -> Data? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.start(timeout: timeout)
        }
    }

    private func start(timeout: TimeInterval) {
        guard let port = NWEndpoint.Port(rawValue: peer.port) else {
            finish(with: nil)
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(peer.ip), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake()
                self.receive()
            case .failed, .cancelled:
                self.finish(with: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(with: nil)
        }
    }

    private func sendHandshake() {
        var reserved = Data(repeating: 0, count: 8)
        reserved[5] = 0x10

        var payload = Data()
        payload.append(0x13)
        payload.append(Data("BitTorrent protocol".utf8))
        payload.append(reserved)
        payload.append(infoHash)
        payload.append(peerId)
        connection?.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.report(progress: 0.1, status: "Contacting metadata peer \(self?.peer.ip ?? "")")
        })
    }

    private func sendExtendedHandshake() {
        let message = BencodeValue.dict([
            "m": .dict([
                "ut_metadata": .int(1),
            ]),
        ])

        guard let payload = try? BencodeEncoder.encode(message) else {
            finish(with: nil)
            return
        }

        sendExtendedMessage(id: 0, payload: payload)
    }

    private func requestNextMetadataPieces() {
        guard let metadataMessageID else { return }

        let pieceCount = Int(ceil(Double(metadataSize) / 16_384.0))
        guard pieceCount > 0 else {
            finish(with: nil)
            return
        }

        while requestedPieces.count - metadataPieces.count < 4,
              maxRequestedPiece + 1 < pieceCount {
            maxRequestedPiece += 1
            requestedPieces.insert(maxRequestedPiece)
            let request = BencodeValue.dict([
                "msg_type": .int(0),
                "piece": .int(maxRequestedPiece),
            ])
            guard let payload = try? BencodeEncoder.encode(request) else {
                finish(with: nil)
                return
            }
            sendExtendedMessage(id: metadataMessageID, payload: payload)
        }
    }

    private func sendExtendedMessage(id: UInt8, payload: Data) {
        var message = Data()
        message.append(bigEndianBytes(UInt32(payload.count + 2)))
        message.append(20)
        message.append(id)
        message.append(payload)
        connection?.send(content: message, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if isComplete || error != nil {
                self.finish(with: nil)
                return
            }

            if !self.hasFinished {
                self.receive()
            }
        }
    }

    private func processReceiveBuffer() {
        if !receivedHandshake {
            guard receiveBuffer.count >= 68 else { return }
            let handshake = receiveBuffer.prefix(68)
            guard handshake.first == 19,
                  Data(handshake[1..<20]) == Data("BitTorrent protocol".utf8),
                  Data(handshake[28..<48]) == infoHash else {
                finish(with: nil)
                return
            }

            peerSupportsExtensions = (handshake[25] & 0x10) != 0
            guard peerSupportsExtensions else {
                finish(with: nil)
                return
            }

            receiveBuffer.removeFirst(68)
            receivedHandshake = true
            sendExtendedHandshake()
        }

        while receiveBuffer.count >= 4 {
            guard let length = readUInt32(receiveBuffer, at: 0).map(Int.init) else {
                finish(with: nil)
                return
            }
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

        if messageID == 20 {
            handleExtendedMessage(message.dropFirst())
        }
    }

    private func handleExtendedMessage(_ payload: Data.SubSequence) {
        guard let extendedMessageID = payload.first else { return }
        let content = Data(payload.dropFirst())

        if extendedMessageID == 0 {
            handleExtendedHandshake(content)
            return
        }

        guard let metadataMessageID, extendedMessageID == metadataMessageID else { return }
        handleMetadataPiece(content)
    }

    private func handleExtendedHandshake(_ payload: Data) {
        guard let decoded = Bencode.decodePrefix(payload),
              let dict = decoded.value.dict,
              let metadataMap = dict["m"]?.dict,
              let utMetadata = metadataMap["ut_metadata"]?.int,
              let metadataSize = dict["metadata_size"]?.int else {
            finish(with: nil)
            return
        }

        if metadataSize <= 0 || metadataSize > 4 * 1024 * 1024 {
            finish(with: nil)
            return
        }

        self.metadataMessageID = UInt8(utMetadata)
        self.metadataSize = metadataSize
        report(progress: 0.35, status: "Requesting \(ByteCountFormatter.string(fromByteCount: Int64(metadataSize), countStyle: .file)) of torrent metadata")
        requestNextMetadataPieces()
    }

    private func handleMetadataPiece(_ payload: Data) {
        guard let decoded = Bencode.decodePrefix(payload),
              let header = decoded.value.dict,
              let messageType = header["msg_type"]?.int,
              let pieceIndex = header["piece"]?.int else {
            finish(with: nil)
            return
        }

        switch messageType {
        case 1:
            guard pieceIndex >= 0 else {
                finish(with: nil)
                return
            }
            let pieceData = payload.subdata(in: decoded.consumed..<payload.count)
            metadataPieces[pieceIndex] = pieceData
            let pieceCount = Int(ceil(Double(metadataSize) / 16_384.0))
            let progress = pieceCount > 0 ? Double(metadataPieces.count) / Double(pieceCount) : 0
            report(progress: 0.35 + (progress * 0.65), status: "Downloading torrent metadata (\(metadataPieces.count)/\(pieceCount) pieces)")

            if let assembledMetadata = assembleMetadataIfComplete() {
                finish(with: assembledMetadata)
            } else {
                requestNextMetadataPieces()
            }
        case 2:
            finish(with: nil)
        default:
            break
        }
    }

    private func assembleMetadataIfComplete() -> Data? {
        let pieceCount = Int(ceil(Double(metadataSize) / 16_384.0))
        guard metadataPieces.count >= pieceCount else { return nil }

        var metadata = Data(capacity: metadataSize)
        for pieceIndex in 0..<pieceCount {
            guard let piece = metadataPieces[pieceIndex] else { return nil }
            metadata.append(piece)
        }

        metadata = metadata.prefix(metadataSize)
        guard let sha1 = CryptoUtils.sha1(metadata), sha1 == infoHash else {
            return nil
        }

        return metadata
    }

    private func report(progress: Double, status: String) {
        onUpdate?(progress, status)
    }

    private func finish(with metadata: Data?) {
        guard !hasFinished else { return }
        hasFinished = true
        let continuation = self.continuation
        self.continuation = nil
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: metadata)
    }
}

private enum UDPDatagramClient {
    static func send(_ payload: Data, host: String, port: UInt16, timeout: TimeInterval = 5) async -> Data? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.neutron.bittorrent.udp.\(host).\(port)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            let lock = NSLock()
            var hasResumed = false

            func finish(_ response: Data?) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: response)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil {
                            finish(nil)
                            return
                        }

                        connection.receiveMessage { data, _, _, _ in
                            finish(data)
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }
}

private func percentEncodedBinary(_ data: Data) -> String {
    data.map { String(format: "%%%02X", $0) }.joined()
}

private func parseCompactPeers(_ data: Data) -> [PeerInfo] {
    stride(from: 0, to: data.count - (data.count % 6), by: 6).map { index in
        let ip = "\(data[index]).\(data[index + 1]).\(data[index + 2]).\(data[index + 3])"
        let port = UInt16(data[index + 4]) << 8 | UInt16(data[index + 5])
        return PeerInfo(ip: ip, port: port, peerId: nil)
    }
}

private func parseCompactNodes(_ data: Data) -> [DHTNode] {
    stride(from: 0, to: data.count - (data.count % 26), by: 26).compactMap { index in
        let host = "\(data[index + 20]).\(data[index + 21]).\(data[index + 22]).\(data[index + 23])"
        let port = UInt16(data[index + 24]) << 8 | UInt16(data[index + 25])
        return DHTNode(host: host, port: port)
    }
}

private func bigEndianBytes(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func bigEndianBytes(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func bigEndianBytes(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset + 4 <= data.count else { return nil }
    return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
}

private func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard offset + 8 <= data.count else { return nil }
    return data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
}

private extension PeerInfo {
    init?(exactPeerValue: String) {
        let decodedValue = exactPeerValue.removingPercentEncoding ?? exactPeerValue
        let parts = decodedValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        self.init(ip: parts[0], port: port, peerId: nil)
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count.isMultiple(of: 2) else { return nil }

        var bytes = Data(capacity: clean.count / 2)
        var cursor = clean.startIndex
        while cursor < clean.endIndex {
            let next = clean.index(cursor, offsetBy: 2)
            guard let byte = UInt8(clean[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        self = bytes
    }

    init?(base32Encoded string: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            lookup[char] = UInt8(index)
        }

        let cleaned = string.uppercased().filter { !$0.isWhitespace && $0 != "=" }
        guard !cleaned.isEmpty else { return nil }

        var buffer: UInt64 = 0
        var bitCount = 0
        var bytes = Data()

        for char in cleaned {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bitCount += 5

            while bitCount >= 8 {
                bitCount -= 8
                let byte = UInt8((buffer >> UInt64(bitCount)) & 0xFF)
                bytes.append(byte)
            }
        }

        guard bytes.count == 20 else { return nil }
        self = bytes
    }
}
