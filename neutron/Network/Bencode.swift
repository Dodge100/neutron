import Foundation

struct Bencode {
    static func decode(_ data: Data) -> BencodeValue? {
        return decode(data, index: 0).0
    }

    static func decodePrefix(_ data: Data) -> (value: BencodeValue, consumed: Int)? {
        let (value, consumed) = decode(data, index: 0)
        guard let value else { return nil }
        return (value, consumed)
    }
    
    private static func decode(_ data: Data, index: Int) -> (BencodeValue?, Int) {
        guard index < data.count else { return (nil, index) }
        
        let byte = data[index]
        
        switch byte {
        case UInt8(ascii: "i"):
            return decodeInt(data, index: index + 1)
        case UInt8(ascii: "l"):
            return decodeList(data, index: index + 1)
        case UInt8(ascii: "d"):
            return decodeDict(data, index: index + 1)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return decodeString(data, index: index)
        default:
            return (nil, index)
        }
    }
    
    private static func decodeInt(_ data: Data, index: Int) -> (BencodeValue?, Int) {
        var endIndex = index
        while endIndex < data.count && data[endIndex] != UInt8(ascii: "e") {
            endIndex += 1
        }
        guard endIndex > index else { return (nil, index) }
        
        let intData = data[index..<endIndex]
        guard let intString = String(data: intData, encoding: .utf8),
              let value = Int(intString) else { return (nil, index) }
        
        return (.int(value), endIndex + 1)
    }
    
    private static func decodeString(_ data: Data, index: Int) -> (BencodeValue?, Int) {
        var colonIndex = index
        while colonIndex < data.count && data[colonIndex] != UInt8(ascii: ":") {
            colonIndex += 1
        }
        guard colonIndex > index else { return (nil, index) }
        
        let lengthData = data[index..<colonIndex]
        guard let lengthString = String(data: lengthData, encoding: .utf8),
              let length = Int(lengthString) else { return (nil, index) }
        
        let startIndex = colonIndex + 1
        let endIndex = startIndex + length
        guard endIndex <= data.count else { return (nil, index) }
        
        let stringData = data[startIndex..<endIndex]
        return (.string(Data(stringData)), endIndex)
    }
    
    private static func decodeList(_ data: Data, index: Int) -> (BencodeValue?, Int) {
        var items: [BencodeValue] = []
        var currentIndex = index
        
        while currentIndex < data.count && data[currentIndex] != UInt8(ascii: "e") {
            let (value, newIndex) = decode(data, index: currentIndex)
            if let value = value {
                items.append(value)
            }
            currentIndex = newIndex
        }
        
        return (.list(items), currentIndex + 1)
    }
    
    private static func decodeDict(_ data: Data, index: Int) -> (BencodeValue?, Int) {
        var dict: [String: BencodeValue] = [:]
        var currentIndex = index
        
        while currentIndex < data.count && data[currentIndex] != UInt8(ascii: "e") {
            let (keyValue, keyEndIndex) = decodeString(data, index: currentIndex)
            guard let keyValue = keyValue, let key = keyValue.string else {
                return (nil, index)
            }
            
            let (value, valueEndIndex) = decode(data, index: keyEndIndex)
            if let value = value {
                dict[key] = value
            }
            currentIndex = valueEndIndex
        }
        
        return (.dict(dict), currentIndex + 1)
    }
}

enum BencodeValue {
    case int(Int)
    case string(Data)
    case list([BencodeValue])
    case dict([String: BencodeValue])
    
    var string: String? {
        if case .string(let data) = self {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
    
    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
    
    var data: Data? {
        if case .string(let data) = self { return data }
        return nil
    }
    
    var dict: [String: BencodeValue]? {
        if case .dict(let dict) = self { return dict }
        return nil
    }
    
    var list: [BencodeValue]? {
        if case .list(let list) = self { return list }
        return nil
    }
}

struct TorrentFile {
    let infoHash: Data
    let name: String
    let length: Int64
    let pieceLength: Int64
    let pieces: Data
    let isMultiFile: Bool
    let files: [TorrentFileEntry]
    let announce: String?
    let announceList: [String]
    
    struct TorrentFileEntry {
        let path: String
        let length: Int64
    }
    
    var pieceCount: Int {
        pieces.count / 20
    }

    init?(data: Data) {
        guard let value = Bencode.decode(data) else { return nil }
        self.init(bencode: value)
    }
    
    init?(bencode: BencodeValue) {
        guard let dict = bencode.dict,
              let info = dict["info"]?.dict,
              let infoData = try? BencodeEncoder.encode(.dict(info)),
              let infoHash = CryptoUtils.sha1(infoData) else { return nil }

        self.init(
            infoHash: infoHash,
            info: info,
            announce: dict["announce"]?.string,
            announceList: Self.parseAnnounceList(dict["announce-list"])
        )
    }

    init?(infoDictionaryData: Data, announce: String?, announceList: [String], expectedInfoHash: Data? = nil) {
        guard let decoded = Bencode.decodePrefix(infoDictionaryData),
              decoded.consumed == infoDictionaryData.count,
              let info = decoded.value.dict,
              let infoHash = CryptoUtils.sha1(infoDictionaryData) else {
            return nil
        }

        if let expectedInfoHash, expectedInfoHash != infoHash {
            return nil
        }

        self.init(
            infoHash: infoHash,
            info: info,
            announce: announce,
            announceList: announceList
        )
    }

    private init?(infoHash: Data, info: [String: BencodeValue], announce: String?, announceList: [String]) {
        self.infoHash = infoHash
        self.announce = announce
        self.announceList = announceList

        guard let name = info["name"]?.string else { return nil }
        self.name = name

        guard let pieceLength = info["piece length"]?.int else { return nil }
        self.pieceLength = Int64(pieceLength)

        guard let pieces = info["pieces"]?.data, !pieces.isEmpty, pieces.count.isMultiple(of: 20) else {
            return nil
        }
        self.pieces = pieces

        if let files = info["files"]?.list {
            self.isMultiFile = true
            let parsedFiles = files.compactMap { fileEntry -> TorrentFileEntry? in
                guard let entry = fileEntry.dict,
                      let path = entry["path"]?.list?.compactMap({ $0.string }).joined(separator: "/"),
                      !path.isEmpty,
                      let length = entry["length"]?.int else {
                    return nil
                }
                return TorrentFileEntry(path: path, length: Int64(length))
            }
            guard !parsedFiles.isEmpty else { return nil }
            self.files = parsedFiles
            self.length = parsedFiles.reduce(0) { $0 + $1.length }
        } else if let length = info["length"]?.int {
            self.isMultiFile = false
            self.length = Int64(length)
            self.files = [TorrentFileEntry(path: name, length: Int64(length))]
        } else {
            return nil
        }
    }

    private static func parseAnnounceList(_ value: BencodeValue?) -> [String] {
        value?.list?
            .flatMap { entry -> [String] in
                if let nested = entry.list {
                    return nested.compactMap(\.string)
                }
                return entry.string.map { [$0] } ?? []
            } ?? []
    }
}

struct BencodeEncoder {
    static func encode(_ value: BencodeValue) throws -> Data {
        var data = Data()
        try encodeValue(value, to: &data)
        return data
    }
    
    private static func encodeValue(_ value: BencodeValue, to data: inout Data) throws {
        switch value {
        case .int(let int):
            data.append(contentsOf: "i\(int)e".utf8)
        case .string(let str):
            data.append(contentsOf: "\(str.count):".utf8)
            data.append(str)
        case .list(let list):
            data.append(UInt8(ascii: "l"))
            for item in list {
                try encodeValue(item, to: &data)
            }
            data.append(UInt8(ascii: "e"))
        case .dict(let dict):
            data.append(UInt8(ascii: "d"))
            for key in dict.keys.sorted() {
                try encodeValue(.string(Data(key.utf8)), to: &data)
                try encodeValue(dict[key]!, to: &data)
            }
            data.append(UInt8(ascii: "e"))
        }
    }
}

struct CryptoUtils {
    static func sha1(_ data: Data) -> Data? {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
    
    static func sha1(_ string: String) -> Data? {
        sha1(Data(string.utf8))
    }
}

import CommonCrypto
