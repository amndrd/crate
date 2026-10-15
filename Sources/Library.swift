import AppKit
import SwiftUI

/// Playlists shown in the picker, with their cover and name fetched from Spotify's public embed info (no login).
/// Covers are cached in ~/Library/Caches/Crate/covers and refreshed once a week.
final class Library: ObservableObject {
    struct Item: Identifiable {
        let id: Int
        let entry: PlaylistEntry
        var name: String
        var cover: NSImage?
        var tint: Color
    }

    @Published var items: [Item]
    private static let folder = cacheDir.appendingPathComponent("covers")
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    init(_ entries: [PlaylistEntry]) {
        items = entries.enumerated().map { index, entry in
            let title = (try? String(contentsOf: Library.titleFile(entry), encoding: .utf8)) ?? ""
            let name = Library.displayName(entry, title, index)
            let cover = Library.customCover(name) ?? NSImage(contentsOf: Library.coverFile(entry))
            return Item(id: index, entry: entry, name: name, cover: cover, tint: dominantColor(cover))
        }
    }

    /// A picture the user put in the covers folder, named after the playlist (covers/Chill.jpg).
    /// Useful for private playlists, whose cover Spotify only shares with their owner.
    private static func customCover(_ name: String) -> NSImage? {
        let folder = projectDir.appendingPathComponent("covers")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased() }.flatMap(NSImage.init(contentsOf:))
    }

    private static func coverFile(_ e: PlaylistEntry) -> URL { folder.appendingPathComponent(e.id + ".jpg") }
    private static func titleFile(_ e: PlaylistEntry) -> URL { folder.appendingPathComponent(e.id + ".txt") }

    private static func displayName(_ entry: PlaylistEntry, _ title: String, _ index: Int) -> String {
        if let name = entry.name { return name }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Playlist \(index + 1)" : title
    }

    /// Downloads missing or week-old covers in the background, updating the picker as they arrive
    func refresh() {
        try? FileManager.default.createDirectory(at: Library.folder, withIntermediateDirectories: true)
        for item in items {
            let file = Library.coverFile(item.entry)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < Library.maxAge { continue }
            Task { await fetch(item) }
        }
    }

    private struct OEmbed: Decodable {
        let title: String?
        let thumbnail_url: String?
    }

    private func fetch(_ item: Item) async {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: item.entry.webURL)]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let info = try? JSONDecoder().decode(OEmbed.self, from: data) else { return }
        try? (info.title ?? "").write(to: Library.titleFile(item.entry), atomically: true, encoding: .utf8)
        var image: NSImage?
        if let url = info.thumbnail_url.flatMap(URL.init(string:)),
           let (imageData, _) = try? await URLSession.shared.data(from: url),
           let downloaded = NSImage(data: imageData) {
            try? imageData.write(to: Library.coverFile(item.entry), options: .atomic)
            image = downloaded
        }
        let cover = image
        await MainActor.run {
            guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[i].name = Library.displayName(item.entry, info.title ?? "", item.id)
            if let cover, Library.customCover(items[i].name) == nil {
                withAnimation(.easeInOut(duration: 0.4)) {
                    items[i].cover = cover
                    items[i].tint = dominantColor(cover)
                }
            }
        }
    }
}

/// Dominant color of a cover: average of its most vivid pixels, brightened for the ambient glow
func dominantColor(_ image: NSImage?) -> Color {
    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Color(white: 0.4) }
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Color(white: 0.4) }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
    var scored: [(score: CGFloat, color: NSColor)] = []
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let c = NSColor(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255, blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
        scored.append((c.saturationComponent * c.brightnessComponent, c))
    }
    let best = scored.sorted { $0.score > $1.score }.prefix(scored.count / 5)
    var sat = 0.0, b = 0.0, x = 0.0, y = 0.0
    for (_, c) in best {
        // Hue is averaged on the color wheel
        x += cos(Double(c.hueComponent) * 2 * .pi); y += sin(Double(c.hueComponent) * 2 * .pi)
        sat += Double(c.saturationComponent); b += Double(c.brightnessComponent)
    }
    let n = Double(max(best.count, 1))
    var h = atan2(y, x) / (2 * .pi); if h < 0 { h += 1 }
    return Color(hue: h, saturation: min(sat / n * 1.1, 0.85), brightness: max(b / n, 0.55))
}
