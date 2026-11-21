import AppKit
import SwiftUI

/// Album art with a two-level cache (memory + disk). Covers are fetched lazily by
/// `CoverAPI`, which falls back to matching the track on 网易云 when the search
/// source has no artwork of its own.
@MainActor
final class ArtworkStore: ObservableObject {
  static let shared = ArtworkStore()

  /// Bumped whenever an image lands, so views re-render without us retaining them.
  @Published private(set) var revision = 0

  private let memory = NSCache<NSString, NSImage>()
  private let queue = DispatchQueue(label: "dev.cadence.player.artwork", qos: .utility)
  private let thumbnails = DispatchQueue(label: "dev.cadence.player.artwork.thumbs", qos: .utility)
  private var pending: [Song] = []
  private var inFlight: Set<String> = []
  private var writing: Set<String> = []
  private let directory: URL
  /// Small on purpose: rows and the player bar never need more than this.
  private let maxConcurrent = 2
  private let maxPixels: CGFloat = 256

  private init() {
    Migration.runIfNeeded()
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    directory = caches.appendingPathComponent("Cadence/Artwork", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    memory.countLimit = 48
  }

  func image(for song: Song) -> NSImage? {
    memory.object(forKey: song.id as NSString)
  }

  /// Queues a lookup. Ordering is FIFO and only a few run at once, so a list of
  /// 30 rows trickles in instead of firing 30 lookups at the network.
  func load(_ song: Song) {
    let key = song.id
    guard image(for: song) == nil, !inFlight.contains(key), !writing.contains(key) else { return }
    let file = file(for: song)
    if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
      memory.setObject(image, forKey: key as NSString)
      revision &+= 1
      return
    }
    pending.append(song)
    drain()
  }

  private func drain() {
    while inFlight.count < maxConcurrent, !pending.isEmpty {
      let song = pending.removeFirst()
      let key = song.id
      inFlight.insert(key)
      Task { [weak self] in
        guard let self else { return }
        let data = await CoverAPI.coverData(for: song, size: 300)
        self.inFlight.remove(key)
        if let data, let image = self.downscale(data) {
          self.memory.setObject(image, forKey: key as NSString)
          self.revision &+= 1
          self.writing.insert(key)
          let file = self.file(for: song)
          self.queue.async {
            try? data.write(to: file)
            Task { @MainActor in self.writing.remove(key) }
          }
        }
        self.drain()
      }
    }
  }

  func clearMemory() {
    memory.removeAllObjects()
    pending.removeAll()
    revision &+= 1
  }

  /// Decodes and shrinks before caching: a 500×500 cover costs ~1 MB resident,
  /// and a list of them is what made the app fat.
  private func downscale(_ data: Data) -> NSImage? {
    guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
    let longest = max(image.size.width, image.size.height)
    guard longest > maxPixels else { return image }
    let scale = maxPixels / longest
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let thumb = NSImage(size: size)
    thumb.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size))
    thumb.unlockFocus()
    return thumb
  }

  private func file(for song: Song) -> URL {
    let safe = song.id
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "-")
    return directory.appendingPathComponent(safe).appendingPathExtension("img")
  }
}

struct ArtworkView: View {
  let song: Song?
  var size: CGFloat
  var corner: CGFloat = 6
  /// Off for list rows: fetching a cover per row would mean dozens of lookups.
  var autoLoad = false

  @ObservedObject private var store = ArtworkStore.shared

  var body: some View {
    Group {
      if let song, let image = store.image(for: song) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
      } else {
        Rectangle()
          .fill(
            LinearGradient(
              colors: [
                (song?.platform.tint ?? Color.accentColor).opacity(0.75),
                (song?.platform.tint ?? Color.accentColor).opacity(0.30),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .overlay(
            Image(systemName: "music.note")
              .font(.system(size: size * 0.34, weight: .medium))
              .foregroundStyle(.white.opacity(0.9))
          )
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.22), radius: size >= 44 ? 8 : 2, x: 0, y: size >= 44 ? 3 : 1)
    .task(id: song?.id) {
      if let song, autoLoad { store.load(song) }
    }
  }
}

/// Three bars that react to playback — the only authored motion in the list.
struct EQBars: View {
  var playing: Bool
  var tint: Color = .accentColor

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !playing || reduceMotion)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(alignment: .bottom, spacing: 2) {
        ForEach(0..<3, id: \.self) { index in
          Capsule()
            .fill(tint)
            .frame(width: 2.5, height: height(index: index, time: t))
        }
      }
      .frame(width: 12, height: 12, alignment: .bottom)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: playing)
    }
  }

  private func height(index: Int, time: TimeInterval) -> CGFloat {
    guard playing else { return index == 1 ? 5 : 3 }
    let speed = [1.7, 2.3, 1.9][index]
    let offset = [0.0, 1.1, 2.3][index]
    let value = (sin(time * speed + offset) + 1) / 2
    return 3 + CGFloat(value) * 9
  }
}

/// Seek bar drawn by hand so the buffered region can be shown:
/// track → buffered → played, with the thumb only on hover/drag.
struct SeekBar: View {
  var position: TimeInterval
  var duration: TimeInterval
  var buffered: TimeInterval
  var onSeek: (TimeInterval) -> Void

  @StateObject private var ui = SeekUI()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let width = max(geometry.size.width, 1)
      let progress = duration > 0 ? min(1, max(0, position / duration)) : 0
      let bufferedRatio = duration > 0 ? min(1, max(0, buffered / duration)) : 0
      let dragging = ui.dragging

      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.10))
          .frame(height: 4)
        Capsule()
          .fill(Color.primary.opacity(0.20))
          .frame(width: width * bufferedRatio, height: 4)
        Capsule()
          .fill(Color.accentColor)
          .frame(width: width * (dragging ? ui.dragValue : progress), height: 4)
        if dragging || ui.hovering {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .offset(x: width * (dragging ? ui.dragValue : progress) - 4.5)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        }
      }
      .frame(height: 14)
      .contentShape(Rectangle())
      .onHover { inside in
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { ui.hovering = inside }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            ui.dragging = true
            ui.dragValue = min(1, max(0, value.location.x / width))
          }
          .onEnded { value in
            let ratio = min(1, max(0, value.location.x / width))
            ui.dragValue = ratio
            ui.dragging = false
            onSeek(ratio * duration)
          }
      )
    }
    .frame(height: 14)
  }
}

final class SeekUI: ObservableObject {
  @Published var dragging = false
  @Published var hovering = false
  @Published var dragValue: Double = 0
}

/// Disk cache bookkeeping for the settings pane.
enum ArtworkCache {
  static var directory: URL {
    (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("Cadence/Artwork", isDirectory: true)
  }

  static func describe() -> String {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey]
    )) ?? []
    let bytes = files.reduce(Int64(0)) { total, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return total + Int64(size)
    }
    return "\(files.count) 张 · \(String(format: "%.1f MB", Double(bytes) / 1_048_576))"
  }

  @MainActor
  static func clear() {
    ArtworkStore.shared.clearMemory()
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
}
