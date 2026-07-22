import AppKit
import QuickLookThumbnailing

final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<Void, any Error>] = [:]
    private let lock = NSLock()

    /// Returns the cached thumbnail immediately, or falls back to the generic system icon.
    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Generates a QuickLook thumbnail and caches it. Calls `update` on the main thread when ready.
    func loadThumbnail(for url: URL, size: CGFloat = 32, update: @escaping () -> Void) {
        let key = url.path as NSString

        // Already cached — nothing to do
        if cache.object(forKey: key) != nil { return }

        lock.lock()
        if inFlight[url.path] != nil { lock.unlock(); return }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size * 2, height: size * 2),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.nsImage
            self.cache.setObject(image, forKey: key)
            await MainActor.run {
                self.lock.lock()
                self.inFlight.removeValue(forKey: url.path)
                self.lock.unlock()
                update()
            }
        }
        inFlight[url.path] = task
        lock.unlock()
    }

    /// Cancel any pending thumbnail loads (e.g. when the view disappears).
    func cancel(url: URL) {
        lock.lock()
        inFlight[url.path]?.cancel()
        lock.unlock()
    }
}
