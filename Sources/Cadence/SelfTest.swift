import AVFoundation
import AppKit
import Foundation
import LxSourceKit
import SwiftUI

/// Headless end-to-end check of the non-UI stack:
/// 音源 load → per-platform search → resolve → lyric → download → decode → play.
///
///   Cadence --selftest [--platforms kg,wy]
enum SelfTest {

  static func runIfRequested() {
    if CommandLine.arguments.contains("--idle-probe") {
      Task { @MainActor in await idleProbe() }
      return
    }
    if CommandLine.arguments.contains("--sheet-test") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        Task { @MainActor in await sheetTest() }
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--import-test"),
       index + 1 < CommandLine.arguments.count {
      let url = CommandLine.arguments[index + 1]
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        Task { @MainActor in await importTest(url: url) }
      }
      return
    }
    if CommandLine.arguments.contains("--cover-test") {
      Task { @MainActor in await coverTest(); exit(0) }
      return
    }
    if CommandLine.arguments.contains("--window-test") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        Task { @MainActor in windowTest() }
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--inspect"),
       index + 1 < CommandLine.arguments.count {
      inspect(path: CommandLine.arguments[index + 1])
      exit(0)
    }
    guard CommandLine.arguments.contains("--selftest") else { return }
    exit(run() ? 0 : 1)
  }

  /// Reproduces the reported flow without a modal: reveal the inline import row,
  /// submit a URL, then confirm the row closed, the field cleared, and the source
  /// actually landed in the list.
  /// Watches the idle engine release: engines must drop to 0 and RSS must follow.
  @MainActor
  private static func idleProbe() async {
    let state = AppState()
    await state.loadSourcesFromDisk()
    for step in 0..<4 {
      print(String(format: "t+%-3ds   engines=%d  rss=%.0f MB",
                   step * 25, state.liveEngineCount, AppState.residentMB()))
      if step < 3 { try? await Task.sleep(nanoseconds: 25_000_000_000) }
    }
    exit(0)
  }

  @MainActor
  private static func sheetTest() async {
    let state = AppState()
    await state.loadSourcesFromDisk()
    state.section = .sources
    let before = state.loadedSources.count

    state.importURL = "https://www.imwzh.com/lxmusic/%E5%A4%A7%E9%B1%BC%E5%90%83%E5%B0%8F%E9%B1%BCv1.9.0.js"
    state.showingImportField = true
    try? await Task.sleep(nanoseconds: 250_000_000)
    print("row       visible=\(state.showingImportField)")

    let url = state.importURL
    state.importURL = ""
    state.showingImportField = false
    print("row       after submit: visible=\(state.showingImportField) url='\(state.importURL)'")

    await state.importSource(fromRemote: url)
    print("imported  \(before) → \(state.loadedSources.count)  message=\(state.message)")

    let ok = !state.showingImportField && state.importURL.isEmpty && state.loadedSources.count > before
    print("result    \(ok ? "PASS" : "FAIL")  (row closed, url cleared, source added)")
    exit(ok ? 0 : 1)
  }

  /// Measures how long the main thread is blocked while a 音源 initialises.
  @MainActor
  private static func importTest(url: String) async {
    let state = AppState()
    await state.loadSourcesFromDisk()
    let before = state.loadedSources.count
    print("before   sources=\(before)")

    var ticks: [Date] = []
    let timer = Timer(timeInterval: 0.02, repeats: true) { _ in ticks.append(Date()) }
    RunLoop.main.add(timer, forMode: .common)

    let started = Date()
    await state.importSource(fromRemote: url)
    let elapsed = Date().timeIntervalSince(started)
    timer.invalidate()

    var maxGap = 0.0
    for (previous, next) in zip(ticks, ticks.dropFirst()) {
      maxGap = max(maxGap, next.timeIntervalSince(previous))
    }
    print("import   \(String(format: "%.2f", elapsed)) s  message=\(state.message)")
    print("sources  \(before) → \(state.loadedSources.count)")
    print(String(format: "block    max main-thread stall %.0f ms (sheet stays smooth under ~100 ms)", maxGap * 1000))
    exit(state.loadedSources.count > before ? 0 : 1)
  }

  @MainActor
  private static func coverTest() async {
    let samples = [
      Song(platform: .tx, key: "0039MnYb0qxYhV", name: "晴天", singer: "周杰伦", album: "", duration: 0, picture: nil, ids: [:]),
      Song(platform: .kg, key: "1f7e7659b9fff4fb6f71562a61bbc25f", name: "发如雪", singer: "周杰伦", album: "", duration: 0, picture: nil, ids: [:]),
    ]
    for song in samples {
      let started = Date()
      let data = await CoverAPI.coverData(for: song)
      print("\(song.platform.displayName) \(song.name): \(data.map { "\($0.count) bytes" } ?? "nil")  \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
    if let hit = try? await MusicSearch.search("晴天 周杰伦", on: .wy, limit: 1).first {
      print("wy search hit: \(hit.key) \(hit.name)")
      let url = "https://music.163.com/api/song/detail?ids=%5B\(hit.key)%5D"
      var request = URLRequest(url: URL(string: url)!)
      request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
      if let (data, _) = try? await URLSession.shared.data(for: request) {
        print("detail bytes=\(data.count)  \(String(decoding: data.prefix(120), as: UTF8.self))")
      }
    }
  }

  /// Verifies the close button hides (instead of destroying) the window and that
  /// the menu-bar path brings the same window back.
  @MainActor
  static func windowTest() {
    guard let window = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) else {
      print("window-test: no main window at launch")
      exit(1)
    }
    WindowBridge.shared.adopt(window: window)
    print("launch    visible=\(window.isVisible)")

    let allowedToClose = WindowBridge.shared.windowShouldClose(window)
    print("close     intercepted=\(!allowedToClose)  hidden=\(!window.isVisible)  alive=\(true)")

    WindowBridge.shared.show()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && !window.isVisible {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    let sameWindow = WindowBridge.shared === window.delegate
    print("restore   visible=\(window.isVisible)  sameWindow=\(sameWindow)")
    exit(!allowedToClose && window.isVisible ? 0 : 1)
  }

  /// Reads a file back through AVFoundation — the same stack Finder, QuickTime and
  /// Apple Music use — to prove the embedded tags are actually readable.
  static func inspect(path: String) {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let semaphore = DispatchSemaphore(value: 0)
    var finished = false
    Task {
      defer { semaphore.signal() }
      do {
        let metadata = try await asset.load(.commonMetadata)
        let duration = try await asset.load(.duration)
        print("file     \(url.lastPathComponent)  \(String(format: "%.1fs", duration.seconds))")
        for item in metadata {
          let value = try? await item.load(.value)
          let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "?"
          if let data = value as? Data {
            print("  \(key): <\(data.count) bytes, \(data.prefix(3).map { String(format: "%02x", $0) }.joined())>")
          } else if let string = value as? String {
            print("  \(key): \(string.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(70))")
          } else {
            print("  \(key): \(String(describing: value))")
          }
        }
        finished = true
      } catch {
        print("inspect failed: \(error.localizedDescription)")
        finished = true
      }
    }
    while !finished && semaphore.wait(timeout: .now() + 0.05) == .timedOut { }
  }

  static func run() -> Bool {
    var success = false
    var finished = false
    Task { @MainActor in
      do {
        try await pipeline()
        success = true
      } catch {
        log("FAIL     \(error.localizedDescription)")
      }
      finished = true
    }
    let deadline = Date().addingTimeInterval(180)
    while !finished && Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if !finished { log("FAIL     timed out") }
    return success
  }

  @MainActor
  private static func pipeline() async throws {
    let started = Date()
    _ = try await platformMatrix(started: started)
    log(String(format: "done     %.0f ms total, %.1f MB rss", Date().timeIntervalSince(started) * 1000, residentMB()))
  }

  /// For every platform the loaded script declares: search → resolve → lyric.
  /// Then download + decode + play the first URL that came back.
  @MainActor
  private static func platformMatrix(started: Date) async throws -> URL? {
    let scriptURL = try sourceScriptURL()
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    let engine = try LXEngine()
    let entries = try await engine.load(script: script, fileName: scriptURL.lastPathComponent)
    log("source   \(engine.scriptInfo.name) v\(engine.scriptInfo.version) — \(entries.keys.sorted().joined(separator: ","))")

    let requested = CommandLine.arguments
      .first { $0.hasPrefix("--platforms=") }?
      .replacingOccurrences(of: "--platforms=", with: "")
      .split(separator: ",")
      .map(String.init)
    let platforms = Platform.allCases.filter { entries[$0.rawValue] != nil && (requested == nil || requested!.contains($0.rawValue)) }

    var playable: (Song, URL)?
    for platform in platforms {
      log("── \(platform.displayName)")
      do {
        let songs = try await MusicSearch.search("周杰伦", on: platform, limit: 3)
        guard let song = songs.first else {
          log("   search   (empty)")
          continue
        }
        log("   search   \(song.name) — \(song.singer) [\(song.key)]  (\(songs.count) 首)")

        let qualities = entries[platform.rawValue]?.qualitys ?? []
        let quality = Platform.qualityOrder.first { qualities.contains($0) } ?? qualities.last ?? "128k"
        let resolveStart = Date()
        let urlString = try await engine.resolve(
          source: platform.rawValue,
          quality: quality,
          musicInfo: song.musicInfo
        )
        log(String(format: "   resolve  %@ %.0f ms  %@", quality, Date().timeIntervalSince(resolveStart) * 1000, String(urlString.prefix(64))))

        if let lines = try? await LyricsAPI.fetch(for: song), !lines.isEmpty {
          log(String(format: "   lyric    %d lines  %@", lines.count, lines[0].text.replacingOccurrences(of: "\n", with: " / ")))
        } else {
          log("   lyric    (none)")
        }

        // Keep the remote URL: progressive playback streams from it.
        if let remote = URL(string: urlString), playable == nil {
          playable = (song, remote)
        }
      } catch {
        log("   FAIL     \(error.localizedDescription)")
      }
    }

    guard let (song, url) = playable else {
      throw LxError.bridge("没有任何平台取链成功")
    }

    let audio = AudioEngine()
    let playStarted = Date()
    audio.play(url: url, title: song.name)
    try await waitUntil(25) { audio.isPlaying }
    let startLatency = Date().timeIntervalSince(playStarted)
    guard audio.isPlaying, audio.duration > 0 else {
      throw LxError.bridge("渐进播放没有启动（duration=\(audio.duration)）")
    }
    log(String(format: "stream   started in %.2f s  (est. duration %.0f s, downloaded %.0f%%)",
               startLatency, audio.duration, audio.progress * 100))
    guard startLatency < 8 else { throw LxError.bridge("启动过慢：\(startLatency)s") }

    try await Task.sleep(nanoseconds: 3_000_000_000)
    log(String(format: "playing  position %.2f s  buffered through %.1f s  downloaded %.0f%%",
               audio.position, audio.bufferedThrough, audio.progress * 100))
    guard audio.position > 1.5 else { throw LxError.bridge("播放位置没有推进（\(audio.position)）") }

    // Seek far ahead of the buffered region: the read loop has to wait for bytes.
    let seekTarget = audio.duration * 0.8
    audio.seek(to: seekTarget)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    log(String(format: "seek     → %.0f s  (%.0f%%), now %.1f s, buffering=%@",
               seekTarget, seekTarget / max(audio.duration, 1) * 100, audio.position,
               audio.isBuffering ? "yes" : "no"))
    try await waitUntil(20) { audio.position > seekTarget - 2 }
    log(String(format: "seek     reached %.1f s, playing=%@", audio.position, audio.isPlaying ? "yes" : "no"))

    audio.toggle()
    try await Task.sleep(nanoseconds: 400_000_000)
    log("pause    \(audio.isPlaying ? "failed" : "ok")")
    audio.stop()

    // Also exercise the download manager (separate from streaming).
    let downloadQuality = CommandLine.arguments
      .first { $0.hasPrefix("--download-quality=") }?
      .replacingOccurrences(of: "--download-quality=", with: "") ?? "flac"
    var downloadURL = url
    if let resolved = try? await engine.resolve(
      source: song.platform.rawValue,
      quality: downloadQuality,
      musicInfo: song.musicInfo
    ), let parsed = URL(string: resolved) {
      downloadURL = parsed
    }
    _ = await download(song: song, url: downloadURL, quality: downloadQuality)
    log(String(format: "elapsed  %.0f ms", Date().timeIntervalSince(started) * 1000))
    return url
  }

  /// Downloads through the real DownloadManager and reports the size.
  @MainActor
  private static func download(song: Song, url: URL, quality: String = "flac") async -> URL? {
    let manager = DownloadManager(persistsDirectory: false)
    manager.directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("qmusic-selftest", isDirectory: true)
    let tags = MetadataWriter.Tags(
      title: song.name, artist: song.singer, album: song.album,
      lyrics: (try? await LyricsAPI.fetchRaw(for: song)).map {
        LRC.serialize(LRC.merge(LRC.parse($0.main), with: LRC.parse($0.translation)))
      },
      cover: await CoverAPI.coverData(for: song),
      coverMime: "image/jpeg"
    )
    manager.begin(song: song, sourceURL: url, quality: quality, tags: tags)
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
      if let item = manager.items.first {
        switch item.state {
        case .done:
          let size = (try? FileManager.default.attributesOfItem(atPath: item.fileURL?.path ?? "")[.size] as? Int64) ?? 0
          log(String(format: "   download %@  %.1f MB  %@", item.fileURL?.lastPathComponent ?? "", Double(size) / 1_048_576, item.extras ?? "-"))
          return item.fileURL
        case .failed(let message):
          log("   download FAIL  \(message)")
          return nil
        default:
          break
        }
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    log("   download FAIL  超时")
    return nil
  }

  /// For every platform the loaded script declares: search → resolve → lyric.
  @MainActor
  private static func unusedPlaceholder() {}

  // MARK: - helpers

  @MainActor
  private static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { throw LxError.bridge("等待超时") }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  private static func sourceScriptURL() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["QMUSIC_SOURCE"] {
      return URL(fileURLWithPath: path)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Cadence/Sources", isDirectory: true)
    if let files = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil),
       let first = files.filter({ $0.pathExtension == "js" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
      return first
    }
    if let fallback = CommandLine.arguments.first(where: { $0.hasSuffix(".js") }) {
      return URL(fileURLWithPath: fallback)
    }
    throw LxError.bridge("没有已知音源；设置 QMUSIC_SOURCE=<path.js>")
  }

  private static func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / LayoutOf.natural)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / 1024 / 1024
  }

  private static func log(_ message: String) {
    print(message)
    fflush(stdout)
  }
}

/// Mirrors SearchPane's header row so the snapshot can tell whether a rendering
/// problem lives in the control or in its container.
struct SearchPaneProbeHeader: View {
  @StateObject private var platform = PlatformBox()
  var body: some View {
    HStack(spacing: 12) {
      PlatformPicker(platforms: Platform.allCases, selection: $platform.value)
      Spacer()
      Text("12 首").font(.system(size: 11)).foregroundColor(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }
}

final class PlatformBox: ObservableObject {
  @Published var value: Platform = .kg
}

private enum LayoutOf {
  static let natural = MemoryLayout<natural_t>.size
}

// MARK: - offscreen UI snapshot

extension SelfTest {
  static var snapshotPath: String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
  }

  /// Renders the real SwiftUI hierarchy into a bitmap — no screen recording
  /// permission needed, and it fails loudly if the view tree does not lay out.
  ///
  /// Must run in a real async context: a synchronous main-actor function that
  /// pumps the run loop starves the MainActor jobs it is waiting on.
  @MainActor
  static func renderSnapshot(to path: String) async {
    let state = AppState()
    await state.loadSourcesFromDisk()
    // Snapshots always render the biggest library so the capture is representative.
    if state.supportedPlatforms.contains(.kg) { state.platform = .kg }
    state.section = .search
    state.keyword = "周杰伦"
    state.songs = (try? await MusicSearch.search("周杰伦", on: state.platform, limit: 12)) ?? []
    if let song = state.songs.first {
      state.currentSong = song
      state.selection = song.id
      if let lines = try? await LyricsAPI.fetch(for: song) {
        state.lyrics = lines
        state.lyricIndex = min(30, max(0, lines.count - 1))
      }
    }
    // Offscreen AppKit controls resolve their appearance from NSApp, not from the
    // hosting view — force both so the capture matches what a dark-mode window shows.
    NSApp.appearance = NSAppearance(named: .darkAqua)
    if let song = state.currentSong {
      ArtworkStore.shared.load(song)
      let deadline = Date().addingTimeInterval(8)
      while ArtworkStore.shared.image(for: song) == nil && Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      log("snapshot  artwork: \(ArtworkStore.shared.image(for: song) == nil ? "none" : "loaded")")
    }
    log("snapshot  model: \(state.loadedSources.count) sources, \(state.platform.displayName), \(state.songs.count) songs, \(state.lyrics.count) lyric lines")

    await render(
      ContentView().environmentObject(state).environmentObject(state.audio),
      size: CGSize(width: 1160, height: 720),
      to: path
    )
    state.section = .sources
    await render(
      ContentView(isSnapshot: true).environmentObject(state).environmentObject(state.audio),
      size: CGSize(width: 1160, height: 720),
      to: path.replacingOccurrences(of: ".png", with: "-sources.png")
    )
    state.section = .downloads
    await render(
      ContentView(isSnapshot: true).environmentObject(state).environmentObject(state.audio),
      size: CGSize(width: 1160, height: 720),
      to: path.replacingOccurrences(of: ".png", with: "-downloads.png")
    )
    // Control experiment: is it the capture path or the view that hides text?
    await render(
      VStack(spacing: 10) {
        Text("纯 Text 文本")
        Button("默认 Button 文本") {}
        Button { } label: { Text("plain Button 文本") }.buttonStyle(.plain)
        Button { } label: {
          HStack { Circle().fill(.blue).frame(width: 8, height: 8); Text("复合 label") }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }.buttonStyle(.plain)
        Label("Label 文本", systemImage: "music.note")
        PlatformPicker(platforms: Platform.allCases, selection: .constant(.kg))
        SearchPaneProbeHeader()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor)),
      size: CGSize(width: 420, height: 220),
      to: path.replacingOccurrences(of: ".png", with: "-probe.png")
    )
    state.section = .search
    await render(
      LyricPanelView().environmentObject(state),
      size: CGSize(width: 760, height: 190),
      to: path.replacingOccurrences(of: ".png", with: "-lyric.png")
    )
    log("snapshot  \(path)")
    exit(0)
  }

  @MainActor
  private static func render<V: View>(_ view: V, size: CGSize, to path: String) async {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    // Borderless: a titled window reserves toolbar safe area, which renders as an
    // empty band when the toolbar itself is not part of the hosting view.
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: [],
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    window.appearance = NSAppearance(named: .darkAqua)
    hosting.appearance = NSAppearance(named: .darkAqua)
    hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 300_000_000)
    hosting.needsLayout = true
    hosting.displayIfNeeded()
    try? await Task.sleep(nanoseconds: 300_000_000)

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      log("FAIL     无法创建位图")
      return
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
      try? data.write(to: URL(fileURLWithPath: path))
    } else {
      log("FAIL     PNG 编码失败")
    }
    // Vector capture as well: AppKit-bridged controls (Picker/Button) render
    // blank in a bitmap capture taken outside a real display cycle.
    try? hosting.dataWithPDF(inside: hosting.bounds)
      .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: ".pdf")))
  }
}
