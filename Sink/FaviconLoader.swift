import Foundation
import ImageIO
import UniformTypeIdentifiers

struct StoredFavicon: Sendable, Equatable {
    let url: URL
    let data: Data
}

struct FaviconLoader: Sendable {
    static let maximumBytes = 262_144
    let fetcher: any SourceFetching

    init(fetcher: any SourceFetching = SourceFetcher(maximumBytes: maximumBytes)) {
        self.fetcher = (fetcher as? SourceFetcher)?.limitingBytes(to: Self.maximumBytes) ?? fetcher
    }

    /// Failure is optional metadata, not a failed capture. No third-party icon service is used.
    func load(source: URL?, preferred: URL? = nil) async -> StoredFavicon? {
        guard let source, ["https", "http"].contains(source.scheme?.lowercased() ?? ""),
              let fallback = URL(string: "/favicon.ico", relativeTo: source)?.absoluteURL
        else { return nil }
        let candidates = preferred.map { $0 == fallback ? [$0] : [$0, fallback] } ?? [fallback]
        for url in candidates {
            guard !Task.isCancelled else { return nil }
            do {
                let response = try await fetcher.fetch(url)
                guard let png = Self.thumbnail(response.data) else { continue }
                return StoredFavicon(url: response.url, data: png)
            } catch { continue }
        }
        return nil
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 16384 else { return nil }
        return output as Data
    }
}
