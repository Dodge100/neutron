import AppKit
import QuickLookThumbnailing

final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    // Thread-safe inFlight tracking using a heap-allocated unfair lock
    private var _inFlight: [String: Task<Void, Never>] = [:]
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    private init() {
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    private func withLock<T>(_ block: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        return try block()
    }

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
        if cache.object(forKey: key) != nil { return }
        let alreadyInFlight = withLock { _inFlight[url.path] != nil }
        if alreadyInFlight { return }

        let task = Task { [weak self] in
            guard let self, let image = await self.generateThumbnail(for: url, size: size) else {
                withLock { _inFlight.removeValue(forKey: url.path) }
                return
            }
            self.cache.setObject(image, forKey: key)
            withLock { _inFlight.removeValue(forKey: url.path) }
            await MainActor.run { update() }
        }
        withLock { _inFlight[url.path] = task }
    }

    /// Cancel any pending thumbnail loads.
    func cancel(url: URL) {
        withLock {
            _inFlight[url.path]?.cancel()
            _inFlight.removeValue(forKey: url.path)
        }
    }

    /// Prefetch a batch of thumbnails at a lower priority.
    func prefetch(urls: [URL], size: CGFloat = 32) {
        for url in urls {
            let key = url.path as NSString
            if cache.object(forKey: key) != nil { continue }
            let alreadyInFlight = withLock { _inFlight[url.path] != nil }
            if alreadyInFlight { continue }

            let task = Task(priority: .background) { [weak self] in
                guard let self, let image = await self.generateThumbnail(for: url, size: size) else { return }
                self.cache.setObject(image, forKey: key)
                withLock { _inFlight.removeValue(forKey: url.path) }
            }
            withLock { _inFlight[url.path] = task }
        }
    }

    private func generateThumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.nsImage
    }
}
