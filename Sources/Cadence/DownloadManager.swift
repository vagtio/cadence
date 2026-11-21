import AppKit
import Foundation
import OSLog

/// Downloads resolved 音源 URLs to disk with per-item progress.
///
/// Uses `URLSession.download(for:delegate:)` — chunked, disk-backed, with progress
/// from the URLSession delegate. (Iterating `bytes(for:)` byte by byte is far too
/// slow for the 20–50 MB FLAC files these 音源 return.)
@MainActor
final class DownloadManager: ObservableObject {

  enum State: Equatable {
    case queued
    case downloading
    case done
    case failed(String)
  }

  struct Item: Identifiable {
    let id = UUID()
    let song: Song
    let quality: String
    var state: State = .queued
    var progress: Double = 0
    var fileURL: URL?
    var bytes: Int64 = 0
    /// Human readable note about what was written (embedded tags or sidecars).
    var extras: String?

    var isFinished: Bool { state == .done }
  }

  @Published private(set) var items: [Item] = []
  @Published var directory: URL {
    didSet { if persistsDirectory { UserDefaults.standard.set(directory.path, forKey: Self.directoryKey) } }
  }

  /// Self-tests and one-off helpers must not overwrite the user's chosen folder.
  private let persistsDirectory: Bool

  private static let directoryKey = "downloadDirectory"
  private static let log = Logger(subsystem: "dev.cadence.player", category: "download")
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var queued: [(id: UUID, song: Song, url: URL, tags: MetadataWriter.Tags?)] = []
  private let maxConcurrent = 3

  init(persistsDirectory: Bool = true) {
    Migration.runIfNeeded()
    self.persistsDirectory = persistsDirectory
    let fallback = FileManager.default
      .urls(for: .musicDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Cadence", isDirectory: true)
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("Cadence")
    if let stored = UserDefaults.standard.string(forKey: Self.directoryKey), !stored.isEmpty {
      directory = URL(fileURLWithPath: stored)
    } else {
      directory = fallback
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  var activeCount: Int {
    items.filter { $0.state == .queued || $0.state == .downloading }.count
  }

  // MARK: - public API

  func begin(song: Song, sourceURL: URL, quality: String, tags: MetadataWriter.Tags?) {
    // Clicking download twice should not queue the same file twice.
    if items.contains(where: { $0.song.id == song.id && $0.quality == quality && $0.state != .failed("") }) {
      return
    }
    let item = Item(song: song, quality: quality)
    items.insert(item, at: 0)
    let identifier = item.id
    if tasks.count >= maxConcurrent {
      queued.append((identifier, song, sourceURL, tags))
    } else {
      start(identifier: identifier, song: song, url: sourceURL, tags: tags)
    }
  }

  func cancel(_ item: Item) {
    tasks[item.id]?.cancel()
    tasks[item.id] = nil
    update(item.id) { $0.state = .failed("已取消") }
  }

  func remove(_ item: Item) {
    tasks[item.id]?.cancel()
    tasks[item.id] = nil
    items.removeAll { $0.id == item.id }
  }

  func clearFinished() {
    items.removeAll { $0.state == .done }
  }

  func reveal(_ item: Item) {
    guard let fileURL = item.fileURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }

  func openDirectory() {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.open(directory)
  }

  // MARK: - work

  private func start(identifier: UUID, song: Song, url: URL, tags: MetadataWriter.Tags?) {
    tasks[identifier] = Task { [weak self] in
      await self?.run(identifier: identifier, song: song, sourceURL: url, tags: tags)
      await MainActor.run { self?.drainQueue() }
    }
  }

  private func drainQueue() {
    while tasks.count < maxConcurrent, !queued.isEmpty {
      let next = queued.removeFirst()
      update(next.id) { $0.state = .downloading }
      start(identifier: next.id, song: next.song, url: next.url, tags: next.tags)
    }
  }

  private func run(identifier: UUID, song: Song, sourceURL: URL, tags: MetadataWriter.Tags?) async {
    update(identifier) { $0.state = .downloading }
    let folder = directory.appendingPathComponent(song.platform.displayName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

      var request = URLRequest(url: sourceURL)
      request.timeoutInterval = 60
      let delegate = ProgressDelegate { [weak self] written, expected in
        guard let self, expected > 0 else { return }
        let ratio = min(0.99, Double(written) / Double(expected))
        Task { @MainActor in
          self.update(identifier) {
            $0.progress = ratio
            $0.bytes = written
          }
        }
      }

      let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
      try Task.checkCancellation()

      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let ext = Self.fileExtension(for: sourceURL, contentType: http.value(forHTTPHeaderField: "Content-Type"))
      let destination = Self.uniqueURL(folder.appendingPathComponent("\(song.fileBaseName).\(ext)"))
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temporary, to: destination)
      let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

      var extras: String?
      if let tags {
        if MetadataWriter.embed(tags, into: destination) {
          extras = "已内嵌封面与歌词"
        } else if MetadataWriter.writeSidecars(tags, beside: destination) {
          extras = "封面与歌词已存为同名文件"
        }
      }

      update(identifier) {
        $0.progress = 1
        $0.bytes = size
        $0.state = .done
        $0.fileURL = destination
        $0.extras = extras
      }
      Self.log.info("downloaded \(destination.lastPathComponent, privacy: .public)")
    } catch is CancellationError {
      update(identifier) { $0.state = .failed("已取消") }
    } catch {
      update(identifier) { $0.state = .failed(error.localizedDescription) }
    }
    tasks[identifier] = nil
  }

  private func update(_ identifier: UUID, _ mutate: (inout Item) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == identifier }) else { return }
    mutate(&items[index])
  }

  // MARK: - helpers

  private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
      self.onProgress = onProgress
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64,
      totalBytesExpectedToWrite: Int64
    ) {
      onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
      // `download(for:delegate:)` returns the file; nothing to do here.
    }
  }

  private static func uniqueURL(_ url: URL) -> URL {
    var candidate = url
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let base = url.deletingPathExtension().lastPathComponent
      candidate = url.deletingLastPathComponent()
        .appendingPathComponent("\(base) \(counter).\(url.pathExtension)")
      counter += 1
    }
    return candidate
  }

  private static func fileExtension(for url: URL, contentType: String?) -> String {
    let known: Set<String> = ["mp3", "flac", "m4a", "aac", "ogg", "wav", "opus"]
    let pathExtension = url.pathExtension.lowercased()
    if known.contains(pathExtension) { return pathExtension }
    switch contentType?.lowercased() ?? "" {
    case let type where type.contains("flac"): return "flac"
    case let type where type.contains("mp4") || type.contains("m4a"): return "m4a"
    case let type where type.contains("ogg"): return "ogg"
    case let type where type.contains("wav"): return "wav"
    default: return "mp3"
    }
  }
}
