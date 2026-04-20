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
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let copyName = ext.isEmpty
                ? "\(baseName) copy"
                : "\(baseName) copy.\(ext)"
            let destURL = directory.appendingPathComponent(copyName)
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
        if let cached = infoCache.object(forKey: url as NSURL) {
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

            let info = FileInfo(
                name: url.lastPathComponent,
                path: url.path,
                size: size,
                created: created,
                modified: modified,
                kind: kind,
                isDirectory: isDirectory,
                permissions: permissions,
                itemCount: itemCount
            )
            infoCache.setObject(FileInfoCacheEntry(info: info), forKey: url as NSURL)
            return info
        } catch {
            lastError = "Failed to get info for \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    private func invalidateCache(for url: URL) {
        infoCache.removeObject(forKey: url as NSURL)
        infoCache.removeObject(forKey: url.deletingLastPathComponent() as NSURL)
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
