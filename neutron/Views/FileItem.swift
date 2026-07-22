import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    var id: URL { path }
    let name: String
    let isDirectory: Bool
    let size: Int64
    let created: Date
    let modified: Date
    let path: URL
    let tags: [String]

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var isHidden: Bool { name.hasPrefix(".") }

    var nsImage: NSImage {
        FileIconCache.shared.icon(for: path)
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return Self.sizeFormatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        Self.dateFormatter.string(from: modified)
    }

    var kindString: String {
        if isDirectory { return "Folder" }
        if let utType = UTType(filenameExtension: path.pathExtension) {
            return utType.localizedDescription ?? path.pathExtension.uppercased()
        }
        return path.pathExtension.isEmpty ? "Document" : path.pathExtension.uppercased()
    }

    nonisolated static func fromURL(_ url: URL, values: URLResourceValues? = nil) -> FileItem? {
        do {
            let resolvedValues = try values ?? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .tagNamesKey,
            ])
            let isDirectory = resolvedValues.isDirectory ?? false
            let size = Int64(resolvedValues.fileSize ?? 0)
            let created = resolvedValues.creationDate ?? resolvedValues.contentModificationDate ?? Date()
            let modified = resolvedValues.contentModificationDate ?? created
            let tags = resolvedValues.tagNames ?? []

            return FileItem(
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                size: size,
                created: created,
                modified: modified,
                path: url,
                tags: tags
            )
        } catch {
            return nil
        }
    }
}

struct FilePreviewItem: Identifiable, Equatable {
    let id: URL
    let name: String
    let isDirectory: Bool
    let path: URL
    let kind: String
    let size: String
    let location: String
    let created: String?
    let modified: String?
    let permissions: String?
    let itemCount: Int?
    let extension_: String?
    let mimeType: String?
    let accessed: String?
    let hardLinks: Int?
    let inode: UInt64?
    let device: UInt64?
    let mode: UInt32?
    let ownerRead: Bool
    let ownerWrite: Bool
    let ownerExecute: Bool
    let groupRead: Bool
    let groupWrite: Bool
    let groupExecute: Bool
    let otherRead: Bool
    let otherWrite: Bool
    let otherExecute: Bool
    let isHidden: Bool
    let isSymbolicLink: Bool
    let sizeOnDisk: String?
    let tags: [String]

    init(file: FileItem, info: FileInfo?) {
        self.id = file.path
        self.name = file.name
        self.isDirectory = file.isDirectory
        self.path = file.path
        self.kind = info?.kind ?? file.kindString
        self.size = {
            if let info {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                return formatter.string(fromByteCount: info.size)
            }
            return file.formattedSize
        }()
        self.location = info?.path ?? file.path.path
        self.created = info?.created.formatted()
        self.modified = info?.modified.formatted() ?? file.formattedDate
        self.permissions = info?.permissions
        self.itemCount = info?.itemCount
        self.extension_ = info?.extension_
        self.mimeType = info?.mimeType
        self.accessed = info?.accessed?.formatted()
        self.hardLinks = info?.hardLinks
        self.inode = info?.inode
        self.device = info?.device
        self.mode = info?.mode
        self.ownerRead = info?.ownerRead ?? false
        self.ownerWrite = info?.ownerWrite ?? false
        self.ownerExecute = info?.ownerExecute ?? false
        self.groupRead = info?.groupRead ?? false
        self.groupWrite = info?.groupWrite ?? false
        self.groupExecute = info?.groupExecute ?? false
        self.otherRead = info?.otherRead ?? false
        self.otherWrite = info?.otherWrite ?? false
        self.otherExecute = info?.otherExecute ?? false
        self.isHidden = info?.isHidden ?? file.name.hasPrefix(".")
        self.isSymbolicLink = info?.isSymbolicLink ?? false
        self.tags = file.tags
        self.sizeOnDisk = {
            if let bytes = info?.sizeOnDisk, bytes > 0 {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                return formatter.string(fromByteCount: bytes)
            }
            return nil
        }()
    }
}
