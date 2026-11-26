import AppKit
import ImageIO
import SwiftUI

@MainActor
final class LogoLoader {
    static let shared = LogoLoader()
    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    init() { cache.countLimit = 3000 }

    func cached(_ url: String) -> NSImage? { cache.object(forKey: url as NSString) }

    func load(_ urlString: String) async -> NSImage? {
        if let img = cached(urlString) { return img }
        let task: Task<CGImage?, Never>
        if let existing = inflight[urlString] {
            task = existing
        } else {
            guard let url = URL(string: urlString) else { return nil }
            task = Task.detached(priority: .utility) {
                guard let (data, _) = try? await AppModel.session.data(from: url) else { return nil }
                return Self.downsample(data, maxPixel: 96)
            }
            inflight[urlString] = task
        }
        let cg = await task.value
        inflight[urlString] = nil
        if let img = cached(urlString) { return img }
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: urlString as NSString)
        return img
    }

    nonisolated private static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

struct LogoView: View {
    let url: String?
    let name: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(2)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 24)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = LogoLoader.shared.cached(url) { image = hit; return }
            image = nil
            image = await LogoLoader.shared.load(url)
        }
    }
}
