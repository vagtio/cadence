import AppKit
import Combine
import Foundation
import LxSourceKit
import MediaPlayer

@MainActor
final class AppState: ObservableObject {

  struct LoadedSource: Identifiable {
    let id: String            // file name
    let url: URL
    let info: LXEngine.ScriptInfo
    let engines: [String: LXEngine.SourceEntry]
  }

  enum Section: Hashable { case search, downloads, sources }

  @Published var section: Section? = .search
  @Published var keyword = "" {
    didSet { scheduleDebouncedSearch() }
  }
  @Published var platform: Platform = .kg {
    didSet { quality = availableQualities(for: platform).first ?? quality }
  }
  @Published var songs: [Song] = []
  @Published var selection: Song.ID?
  @Published var isSearching = false
  @Published var message = "导入音源后即可搜索与播放"
  @Published var currentSong: Song?
  @Published var lyrics: [LyricLine] = []
  @Published var lyricIndex: Int?
  @Published var quality = "320k"
  @Published var loadedSources: [LoadedSource] = []
  @Published var activeSourceID: String? {
    didSet {
      syncAfterSourceChange()
      pruneEngines(keeping: activeSourceID)
    }
  }
  @Published var showLyricPanel = false {
    didSet { lyricPanel.setVisible(showLyricPanel, state: self) }
  }
  /// Write cover + lyrics into the downloaded file (MP3) or beside it (FLAC/M4A).
  /// Inline import row (no modal): a sheet attached to a pane that an import
  /// rebuilds can stay presented, and a paste-a-URL task never needed a modal.
  @Published var showingImportField = false
  @Published var importURL = ""
  @Published var isImporting = false
  @Published var embedTags: Bool = (UserDefaults.standard.object(forKey: "embedTags") as? Bool) ?? true {
    didSet { UserDefaults.standard.set(embedTags, forKey: "embedTags") }
  }

  let audio = AudioEngine()
  let lyricPanel = LyricPanelController()
  let downloads = DownloadManager()

  private var engines: [String: LXEngine] = [:]
  private var bag: Set<AnyCancellable> = []
  private var searchTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var idleRelease: Task<Void, Never>?
  private let storeDirectory: URL

  /// Cached metadata so startup does not have to execute every 音源 script.
  private struct SourceMeta: Codable {
    struct Entry: Codable {
      let type: String
      let actions: [String]
      let qualitys: [String]
    }
    let name: String
    let version: String
    let author: String
    let homepage: String
    let size: Int
    let modified: Double
    let engines: [String: Entry]
  }

  private enum Key {
    static let platform = "preferredPlatform"
    static let quality = "preferredQuality"
    static let section = "preferredSection"
  }

  init() {
    Migration.runIfNeeded()
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    storeDirectory = base.appendingPathComponent("Cadence/Sources", isDirectory: true)
    try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

    audio.$position
      .receive(on: RunLoop.main)
      .sink { [weak self] position in
        guard let self else { return }
        self.lyricIndex = LRC.currentIndex(in: self.lyrics, at: position)
        self.refreshNowPlayingElapsed()
      }
      .store(in: &bag)

    audio.$isPlaying
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] playing in
        guard let self else { return }
        self.updateNowPlayingRate(playing)
        if playing, let song = self.currentSong {
          self.message = "正在播放：\(song.name)"
        }
      }
      .store(in: &bag)

    audio.$progress
      .receive(on: RunLoop.main)
      .sink { [weak self] progress in
        guard let self, self.audio.isLoading, progress > 0, let song = self.currentSong else { return }
        self.message = "缓冲《\(song.name)》\(Int(progress * 100))%"
      }
      .store(in: &bag)

    downloads.$items
      .receive(on: RunLoop.main)
      .sink { [weak self] items in
        guard let self else { return }
        let done = items.filter { $0.state == .done }.count
        if done > 0, self.section == .downloads {
          self.message = "下载完成 \(done) 首"
        }
      }
      .store(in: &bag)

    if let stored = UserDefaults.standard.string(forKey: Key.platform),
       let restored = Platform(rawValue: stored) {
      platform = restored
    }
    if let stored = UserDefaults.standard.string(forKey: Key.quality), !stored.isEmpty {
      quality = stored
    }
    if let stored = UserDefaults.standard.string(forKey: Key.section) {
      switch stored {
      case "downloads": section = .downloads
      case "sources": section = .sources
      default: section = .search
      }
    }
    // In menu-bar mode we are not resolving anything; drop the JS engine sooner.
    NotificationCenter.default.addObserver(
      forName: .cadenceWindowHidden,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.idleRelease?.cancel()
      self.idleRelease = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        await MainActor.run {
          guard let self, !self.engines.isEmpty else { return }
          self.pruneEngines(keeping: nil)
          NSLog("音源引擎随窗口关闭释放")
        }
      }
    }

    configureRemoteCommands()
    persistPreferences()
  }

  private func persistPreferences() {
    Publishers.CombineLatest3(
      $platform.map(\.rawValue).removeDuplicates(),
      $quality.removeDuplicates(),
      $section.map { section in
        switch section {
        case .downloads: return "downloads"
        case .sources: return "sources"
        default: return "search"
        }
      }.removeDuplicates()
    )
    .sink { platform, quality, section in
      let defaults = UserDefaults.standard
      defaults.set(platform, forKey: Key.platform)
      defaults.set(quality, forKey: Key.quality)
      defaults.set(section, forKey: Key.section)
    }
    .store(in: &bag)
  }

  // MARK: - derived

  var activeSource: LoadedSource? {
    loadedSources.first { $0.id == activeSourceID } ?? loadedSources.first
  }

  /// Test hook: how many 音源 JS engines are alive right now.
  var liveEngineCount: Int { engines.count }

  var supportedPlatforms: [Platform] {
    guard let engines = activeSource?.engines else { return [] }
    return Platform.allCases.filter { engines[$0.rawValue] != nil }
  }

  func availableQualities(for platform: Platform) -> [String] {
    guard let entry = activeSource?.engines[platform.rawValue] else { return [] }
    let ordered = Platform.qualityOrder.filter { entry.qualitys.contains($0) }
    return ordered.isEmpty ? entry.qualitys : ordered
  }

  var sourceDirectory: URL { storeDirectory }

  /// Only the active 音源 keeps a live JS engine; the rest are released so their
  /// heaps go back to the system. Switching back reloads the script on demand.
  private var manifestURL: URL {
    storeDirectory.deletingLastPathComponent().appendingPathComponent("sources.json")
  }

  private func readManifest() -> [String: SourceMeta] {
    guard let data = try? Data(contentsOf: manifestURL),
          let decoded = try? JSONDecoder().decode([String: SourceMeta].self, from: data) else { return [:] }
    return decoded
  }

  private func writeManifest(_ manifest: [String: SourceMeta]) {
    guard let data = try? JSONEncoder().encode(manifest) else { return }
    try? data.write(to: manifestURL)
  }

  private func stamp(of url: URL) -> (size: Int, modified: Double) {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return (values?.fileSize ?? 0, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
  }

  /// 音源 scripts often arm their own timers (heartbeats, card checks). Keeping a
  /// warm engine forever means that work never stops, so drop it after a while and
  /// rebuild on the next request — the reload costs well under a second.
  private func scheduleIdleRelease() {
    idleRelease?.cancel()
    idleRelease = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 90_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.audio.suspendIfIdle()
        guard !self.engines.isEmpty else { return }
        self.pruneEngines(keeping: nil)
        AppState.releaseMemoryToOS()
        print("idle     engines=\(self.engines.count)  rss=\(AppState.residentMB()) MB")
      }
    }
  }

  private func pruneEngines(keeping id: String?) {
    for key in engines.keys where key != id {
      engines[key] = nil
    }
  }

  private func engine(for source: LoadedSource) async -> LXEngine? {
    if let existing = engines[source.id] { return existing }
    guard let script = try? String(contentsOf: source.url, encoding: .utf8),
          let engine = try? LXEngine() else { return nil }
    _ = try? await engine.load(script: script, fileName: source.id)
    engines[source.id] = engine
    scheduleIdleRelease()
    return engine
  }

  /// Ask malloc to hand free pages back — dropping a JSVirtualMachine frees the
  /// heap, but macOS keeps the arena resident until pressure relief runs.
  static func releaseMemoryToOS() {
    malloc_zone_pressure_relief(nil, 0)
  }

  static func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / 1024 / 1024
  }

  private func syncAfterSourceChange() {
    if !supportedPlatforms.contains(platform), let first = supportedPlatforms.first {
      platform = first
    }
    quality = availableQualities(for: platform).first ?? "128k"
  }

  // MARK: - sources

  func loadSourcesFromDisk() async {
    let files = (try? FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?
      .filter { $0.pathExtension == "js" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

    var manifest = readManifest()
    var loaded: [LoadedSource] = []
    var dirty = false

    for file in files {
      let id = file.lastPathComponent
      let stamp = stamp(of: file)
      if let cached = manifest[id],
         cached.size == stamp.size,
         abs(cached.modified - stamp.modified) < 1 {
        let entries = cached.engines.mapValues {
          LXEngine.SourceEntry(type: $0.type, actions: $0.actions, qualitys: $0.qualitys)
        }
        loaded.append(LoadedSource(
          id: id,
          url: file,
          info: LXEngine.ScriptInfo(
            name: cached.name, description: "", version: cached.version,
            author: cached.author, homepage: cached.homepage
          ),
          engines: entries
        ))
        continue
      }

      guard let script = try? String(contentsOf: file, encoding: .utf8),
            let engine = try? LXEngine(),
            let entries = try? await engine.load(script: script, fileName: id),
            !entries.isEmpty else {
        NSLog("音源 \(id) 初始化失败")
        continue
      }
      engines[id] = engine
      let info = engine.scriptInfo
      manifest[id] = SourceMeta(
        name: info.name, version: info.version, author: info.author, homepage: info.homepage,
        size: stamp.size, modified: stamp.modified,
        engines: entries.mapValues { .init(type: $0.type, actions: $0.actions, qualitys: $0.qualitys) }
      )
      dirty = true
      loaded.append(LoadedSource(id: id, url: file, info: info, engines: entries))
    }

    if dirty { writeManifest(manifest) }
    loadedSources = loaded
    if activeSourceID == nil || !loaded.contains(where: { $0.id == activeSourceID }) {
      activeSourceID = loaded.first?.id
    }
    syncAfterSourceChange()
    pruneEngines(keeping: activeSourceID)
    if let active = loadedSources.first(where: { $0.id == activeSourceID }), engines[active.id] == nil {
      _ = await engine(for: active)
    }
    if !loaded.isEmpty {
      message = "已加载 \(loaded.count) 个音源 · 支持 \(supportedPlatforms.map(\.displayName).joined(separator: "/"))"
    }
    scheduleIdleRelease()
  }

  func importSource() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "选择 LX 音源脚本（.js）"
    panel.prompt = "导入"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      // Two scripts often share the file name "latest.js" — keep both.
      var destination = storeDirectory.appendingPathComponent(url.lastPathComponent)
      if FileManager.default.fileExists(atPath: destination.path),
         (try? String(contentsOf: destination, encoding: .utf8)) != (try? String(contentsOf: url, encoding: .utf8)) {
        let stem = url.deletingPathExtension().lastPathComponent
        destination = storeDirectory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(4)).js")
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: url, to: destination)
      Task { await loadSourcesFromDisk() }
    } catch {
      message = "导入失败：\(error.localizedDescription)"
    }
  }

  /// Import from a URL — the online 音源 indexes all publish "copy import link".
  /// Runs off the button action so the sheet can dismiss and animate out before the
  /// (main-thread, blocking) JavaScriptCore evaluation starts.
  func importSource(fromRemote urlString: String) async {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else {
      message = "链接无效"
      return
    }
    isImporting = true
    defer { isImporting = false }

    message = "正在下载音源脚本…"
    do {
      let (temporary, response) = try await URLSession.shared.download(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        message = "下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）"
        return
      }
      var name = url.lastPathComponent.removingPercentEncoding ?? "source.js"
      if !name.lowercased().hasSuffix(".js") { name += ".js" }
      var destination = storeDirectory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: destination.path) {
        destination = storeDirectory.appendingPathComponent("\(name.dropLast(3))-\(UUID().uuidString.prefix(4)).js")
      }
      try FileManager.default.moveItem(at: temporary, to: destination)

      message = "正在初始化「\(destination.lastPathComponent)」…"
      // Let the sheet finish dismissing before the evaluation blocks the main thread.
      try? await Task.sleep(nanoseconds: 120_000_000)
      await loadSourcesFromDisk()
      message = "已导入 \(destination.lastPathComponent)"
    } catch {
      message = "导入失败：\(error.localizedDescription)"
    }
  }

  func remove(_ source: LoadedSource) {
    try? FileManager.default.removeItem(at: source.url)
    engines[source.id] = nil
    var manifest = readManifest()
    manifest[source.id] = nil
    writeManifest(manifest)
    if activeSourceID == source.id { activeSourceID = nil }
    Task { await loadSourcesFromDisk() }
  }

  // MARK: - search

  private func scheduleDebouncedSearch() {
    debounceTask?.cancel()
    let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 2 else { return }
    debounceTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 450_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run { self?.search() }
    }
  }

  func search() {
    let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let target = platform
    searchTask?.cancel()
    isSearching = true
    message = "在「\(target.displayName)」搜索…"
    searchTask = Task {
      do {
        let result = try await MusicSearch.search(text, on: target, limit: 40)
        guard !Task.isCancelled, target == platform, text == self.keyword.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        songs = result
        isSearching = false
        message = result.isEmpty ? "没有找到结果" : "「\(target.displayName)」· 找到 \(result.count) 首"
      } catch {
        guard !Task.isCancelled else { return }
        songs = []
        isSearching = false
        message = "「\(target.displayName)」搜索失败：\(error.localizedDescription)"
      }
    }
  }

  // MARK: - playback

  func play(_ song: Song) {
    Task { await playAsync(song) }
  }

  private func playAsync(_ song: Song) async {
    guard let source = activeSource else {
      message = "请先导入音源脚本"
      return
    }
    guard let engine = await engine(for: source) else {
      message = "\(source.info.name) 初始化失败"
      return
    }
    guard let entry = source.engines[song.platform.rawValue] else {
      message = "当前音源不支持「\(song.platform.displayName)」"
      return
    }
    currentSong = song
    lyrics = []
    lyricIndex = nil
    selection = song.id

    let qualities = entry.qualitys
    let chosen = qualities.contains(quality) ? quality : (Platform.qualityOrder.first { qualities.contains($0) } ?? qualities.last ?? "128k")
    self.quality = chosen
    message = "取链中（\(song.platform.displayName) · \(chosen)）…"

    do {
      let urlString = try await engine.resolve(
        source: song.platform.rawValue,
        quality: chosen,
        musicInfo: song.musicInfo
      )
      guard let url = URL(string: urlString) else {
        message = "音源返回的地址无效"
        return
      }
      audio.play(url: url, title: song.name)
      updateNowPlaying(song)
      scheduleIdleRelease()
      Task {
        if let lines = try? await LyricsAPI.fetch(for: song), !lines.isEmpty {
          lyrics = lines
        }
      }
    } catch {
      message = "取链失败：\(error.localizedDescription)"
    }
  }

  func playSelected() {
    guard let id = selection, let song = songs.first(where: { $0.id == id }) else { return }
    play(song)
  }

  func step(_ offset: Int) {
    guard !songs.isEmpty else { return }
    let current = currentSong.flatMap { song in songs.firstIndex(of: song) } ?? -1
    let next = (current + offset + songs.count) % songs.count
    play(songs[next])
  }

  // MARK: - download

  func download(_ song: Song, quality requested: String? = nil) {
    guard let source = activeSource else {
      message = "请先导入音源脚本"
      return
    }
    guard let entry = source.engines[song.platform.rawValue] else {
      message = "当前音源不支持「\(song.platform.displayName)」"
      return
    }
    let available = availableQualities(for: song.platform)
    let chosen: String
    if let requested, entry.qualitys.contains(requested) {
      chosen = requested
    } else if available.contains(quality) {
      chosen = quality
    } else {
      chosen = available.first ?? entry.qualitys.last ?? "128k"
    }

    message = "准备下载：\(song.name)（\(chosen)）"
    Task {
      guard let engine = await engine(for: source) else {
        message = "\(source.info.name) 初始化失败"
        return
      }
      do {
        let urlString = try await engine.resolve(
          source: song.platform.rawValue,
          quality: chosen,
          musicInfo: song.musicInfo
        )
        guard let url = URL(string: urlString) else {
          message = "音源返回的地址无效"
          return
        }

        var tags: MetadataWriter.Tags?
        if embedTags {
          message = "获取封面与歌词：\(song.name)"
          let raw = try? await LyricsAPI.fetchRaw(for: song)
          let lyricText = raw.map { value in
            LRC.serialize(LRC.merge(LRC.parse(value.main), with: LRC.parse(value.translation)))
          }
          let cover = await CoverAPI.coverData(for: song)
          tags = MetadataWriter.Tags(
            title: song.name,
            artist: song.singer,
            album: song.album,
            lyrics: lyricText,
            cover: cover,
            coverMime: Self.imageMime(cover)
          )
        }

        downloads.begin(song: song, sourceURL: url, quality: chosen, tags: tags)
        message = "已加入下载：\(song.name)（\(chosen)）"
        scheduleIdleRelease()
      } catch {
        message = "下载取链失败：\(error.localizedDescription)"
      }
    }
  }

  /// The row the user picked, falling back to whatever is playing so ⌘D is never
  /// a dead key.
  var selectedSong: Song? {
    if let id = selection, let song = songs.first(where: { $0.id == id }) { return song }
    return currentSong
  }

  func downloadSelected(quality requested: String? = nil) {
    guard let song = selectedSong else { return }
    download(song, quality: requested)
  }

  private static func imageMime(_ data: Data?) -> String {
    guard let data, data.count >= 4 else { return "image/jpeg" }
    let bytes = [UInt8](data.prefix(4))
    if bytes[0] == 0x89, bytes[1] == 0x50 { return "image/png" }
    return "image/jpeg"
  }

  // MARK: - now playing / media keys

  private func updateNowPlaying(_ song: Song) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: song.name,
      MPMediaItemPropertyArtist: song.singer,
      MPMediaItemPropertyAlbumTitle: song.album,
      MPNowPlayingInfoPropertyPlaybackRate: 1.0,
    ]
    if audio.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = audio.duration }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// Keeps the lock-screen / Control Center progress in step with playback.
  private func refreshNowPlayingElapsed() {
    guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audio.position
    if audio.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = audio.duration }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func updateNowPlayingRate(_ playing: Bool) {
    guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audio.position
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in
      guard let self, !self.audio.isPlaying else { return .commandFailed }
      Task { @MainActor in self.audio.toggle() }
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      guard let self, self.audio.isPlaying else { return .commandFailed }
      Task { @MainActor in self.audio.toggle() }
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.audio.toggle() }
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.step(1) }
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.step(-1) }
      return .success
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      Task { @MainActor in self.audio.seek(to: event.positionTime) }
      return .success
    }
  }
}
