//
//  FileOperations.swift
//  neutron
//
//  Created by Dodge1 on 3/11/26.
//

import AppKit
import Combine
import Quartz
import UniformTypeIdentifiers

private final class FileInfoCacheEntry {
    let info: FileInfo

    init(info: FileInfo) {
        self.info = info
    }
}

// MARK: - FileInfo

struct FileInfo {
    let name: String
    let path: String
    let size: Int64
    let created: Date
    let modified: Date
    let kind: String
    let isDirectory: Bool
    let permissions: String
    let itemCount: Int?
    let extension_: String
    let mimeType: String
    let accessed: Date?
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
    let sizeOnDisk: Int64?
}

// MARK: - FileOperations

class FileOperations: ObservableObject {
    @Published var lastError: String?
    private(set) var isCutOperation = false
    private let infoCache = NSCache<NSURL, FileInfoCacheEntry>()

    var clipboardURLs: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    }

    func moveToTrash(urls: [URL]) -> Int {
        var trashedCount = 0
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashedCount += 1
                invalidateCache(for: url)
            } catch {
                lastError = "Failed to trash \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return trashedCount
    }

    func copyFiles(urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        isCutOperation = false
    }

    func cutFiles(urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        isCutOperation = true
    }

    func pasteFiles(to destination: URL) {
        let urls = clipboardURLs
        guard !urls.isEmpty else {
            lastError = "Nothing to paste"
            return
        }

        let fileManager = FileManager.default
        for url in urls {
            let destURL = destination.appendingPathComponent(url.lastPathComponent)
            do {
                if isCutOperation {
                    try fileManager.moveItem(at: url, to: destURL)
                } else {
                    try fileManager.copyItem(at: url, to: destURL)
                }
            } catch {
                lastError = "Failed to paste \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if isCutOperation {
            isCutOperation = false
            NSPasteboard.general.clearContents()
        }
    }

    @discardableResult
    func moveFiles(urls: [URL], to destinationDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let destination = destinationDirectory.standardizedFileURL
        var moved = false

        for sourceURL in urls where sourceURL.isFileURL {
            let source = sourceURL.standardizedFileURL
            let parent = source.deletingLastPathComponent().standardizedFileURL

            if source == destination || parent == destination {
                continue
            }

            if source.hasDirectoryPath,
               destination.path.hasPrefix(source.path + "/") {
                continue
            }

            var candidate = destination.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) {
                candidate = uniqueDestinationURL(for: source, in: destination)
            }

            do {
                try fileManager.moveItem(at: source, to: candidate)
                invalidateCache(for: source)
                invalidateCache(for: candidate)
                moved = true
            } catch {
                lastError = "Failed to move \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if moved {
            invalidateCache(for: destination)
        }

        return moved
    }

    func createNewFolder(in directory: URL, name: String) -> URL? {
        let folderURL = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
            invalidateCache(for: directory)
            return folderURL
        } catch {
            lastError = "Failed to create folder: \(error.localizedDescription)"
            return nil
        }
    }

    func createNewFile(in directory: URL, name: String) -> URL? {
        let fileURL = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            lastError = "A file named \(name) already exists"
            return nil
        }

        guard FileManager.default.createFile(atPath: fileURL.path, contents: Data()) else {
            lastError = "Failed to create file"
            return nil
        }

        invalidateCache(for: directory)
        return fileURL
    }

    func renameFile(at url: URL, to newName: String) -> URL? {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            invalidateCache(for: url)
            invalidateCache(for: newURL)
            return newURL
        } catch {
            lastError = "Failed to rename \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func duplicateFiles(urls: [URL], in directory: URL) {
        let fileManager = FileManager.default
        for url in urls {
            let ext = url.pathExtension
            let baseName = url.deletingPathExtension().lastPathComponent
            let copyName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
            var destURL = directory.appendingPathComponent(copyName)
            if fileManager.fileExists(atPath: destURL.path) {
                destURL = uniqueDestinationURL(for: url, in: directory)
            }
            do {
                try fileManager.copyItem(at: url, to: destURL)
                invalidateCache(for: destURL)
            } catch {
                lastError = "Failed to duplicate \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func deleteFiles(urls: [URL]) {
        let fileManager = FileManager.default
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
                invalidateCache(for: url)
            } catch {
                lastError = "Failed to delete \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func getFileInfo(url: URL) -> FileInfo? {
        let standardized = url.standardizedFileURL
        if let cached = infoCache.object(forKey: standardized as NSURL) {
            return cached.info
        }

        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size = (attributes[.size] as? Int64) ?? 0
            let created = (attributes[.creationDate] as? Date) ?? Date()
            let modified = (attributes[.modificationDate] as? Date) ?? Date()
            let posixPermissions = (attributes[.posixPermissions] as? Int) ?? 0
            let permissions = String(posixPermissions, radix: 8)

            let kind: String
            if isDirectory {
                kind = "Folder"
            } else if let utType = UTType(filenameExtension: url.pathExtension) {
                kind = utType.localizedDescription ?? utType.identifier
            } else {
                kind = "Document"
            }

            var itemCount: Int? = nil
            if isDirectory {
                let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
                itemCount = contents?.count
            }

            let extension_ = url.pathExtension.isEmpty ? "--" : ".\(url.pathExtension)"

            let mimeType: String
            if let utType = UTType(filenameExtension: url.pathExtension) {
                mimeType = utType.preferredMIMEType ?? "--"
            } else {
                mimeType = "--"
            }

            var accessed: Date?
            var hardLinks: Int?
            var inode: UInt64?
            var device: UInt64?
            var mode: mode_t = mode_t(posixPermissions)
            var ownerRead  = (mode & S_IRUSR) != 0
            var ownerWrite = (mode & S_IWUSR) != 0
            var ownerExec  = (mode & S_IXUSR) != 0
            var groupRead  = (mode & S_IRGRP) != 0
            var groupWrite = (mode & S_IWGRP) != 0
            var groupExec  = (mode & S_IXGRP) != 0
            var otherRead  = (mode & S_IROTH) != 0
            var otherWrite = (mode & S_IWOTH) != 0
            var otherExec  = (mode & S_IXOTH) != 0

            var statInfo = stat()
            let statSucceeded = stat(url.path, &statInfo) == 0
            if statSucceeded {
                accessed = Date(timeIntervalSince1970: TimeInterval(statInfo.st_atimespec.tv_sec))
                hardLinks = Int(statInfo.st_nlink)
                inode = statInfo.st_ino
                device = UInt64(statInfo.st_dev)
                mode = statInfo.st_mode
                ownerRead  = (mode & S_IRUSR) != 0
                ownerWrite = (mode & S_IWUSR) != 0
                ownerExec  = (mode & S_IXUSR) != 0
                groupRead  = (mode & S_IRGRP) != 0
                groupWrite = (mode & S_IWGRP) != 0
                groupExec  = (mode & S_IXGRP) != 0
                otherRead  = (mode & S_IROTH) != 0
                otherWrite = (mode & S_IWOTH) != 0
                otherExec  = (mode & S_IXOTH) != 0
            }

            let symlinkExists = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            let sizeOnDisk: Int64?
            if statSucceeded && !isDirectory {
                sizeOnDisk = Int64(statInfo.st_blocks) * 512
            } else {
                sizeOnDisk = nil
            }

            let info = FileInfo(
                name: url.lastPathComponent,
                path: url.path,
                size: size,
                created: created,
                modified: modified,
                kind: kind,
                isDirectory: isDirectory,
                permissions: permissions,
                itemCount: itemCount,
                extension_: extension_,
                mimeType: mimeType,
                accessed: accessed,
                hardLinks: hardLinks,
                inode: inode,
                device: device,
                mode: UInt32(mode),
                ownerRead: ownerRead,
                ownerWrite: ownerWrite,
                ownerExecute: ownerExec,
                groupRead: groupRead,
                groupWrite: groupWrite,
                groupExecute: groupExec,
                otherRead: otherRead,
                otherWrite: otherWrite,
                otherExecute: otherExec,
                isHidden: url.lastPathComponent.hasPrefix("."),
                isSymbolicLink: symlinkExists,
                sizeOnDisk: sizeOnDisk
            )
            infoCache.setObject(FileInfoCacheEntry(info: info), forKey: standardized as NSURL)
            return info
        } catch {
            lastError = "Failed to get info for \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    private func invalidateCache(for url: URL) {
        infoCache.removeObject(forKey: url.standardizedFileURL as NSURL)
        infoCache.removeObject(forKey: url.deletingLastPathComponent().standardizedFileURL as NSURL)
    }

    private func uniqueDestinationURL(for source: URL, in directory: URL) -> URL {
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent

        var counter = 2
        let maxAttempts = 1000
        while counter <= maxAttempts {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(base) \(counter)"
            } else {
                candidateName = "\(base) \(counter).\(ext)"
            }

            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }

            counter += 1
        }

        let fallbackName: String
        if ext.isEmpty {
            fallbackName = "\(base) \(UUID().uuidString.prefix(8))"
        } else {
            fallbackName = "\(base) \(UUID().uuidString.prefix(8)).\(ext)"
        }
        return directory.appendingPathComponent(fallbackName)
    }
}

// MARK: - QuickLookCoordinator

class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    var previewItems: [URL] = []

    func preview(urls: [URL]) {
        previewItems = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        PreviewItem(url: previewItems[index])
    }
}

// MARK: - PreviewItem

class PreviewItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { url.lastPathComponent }
}
