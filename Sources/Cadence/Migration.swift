import Foundation

/// One-time move from the old bundle identity so音源, 下载和偏好不会失联。
enum Migration {
  static let oldBundleID = "dev.lxspike.qmusicnative"
  static let newBundleID = "dev.cadence.player"
  private static let flagKey = "didMigrateFromQMusicNative"

  private static var hasRun = false

  static func runIfNeeded() {
    guard !hasRun else { return }
    hasRun = true
    // Cheap and idempotent: keep it outside the one-shot guard so folders left
    // over from earlier builds still get renamed.
    migrateDownloadFolders()
    guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let library = home.appendingPathComponent("Library", isDirectory: true)

    move(
      library.appendingPathComponent("Application Support/QMusicNative"),
      to: library.appendingPathComponent("Application Support/Cadence")
    )
    move(
      library.appendingPathComponent("Caches/QMusicNative"),
      to: library.appendingPathComponent("Caches/Cadence")
    )
    move(
      home.appendingPathComponent("Music/Q Music"),
      to: home.appendingPathComponent("Music/Cadence")
    )

    migrateDefaults()
    UserDefaults.standard.set(true, forKey: flagKey)
  }

  /// Download folders were named after the upstream platforms before the rename.
  private static func migrateDownloadFolders() {
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Music/Cadence", isDirectory: true)
    let names: [(String, String)] = [
      ("酷狗", "鲸"), ("网易云", "焰"), ("酷我", "珀"), ("QQ 音乐", "萤"),
    ]
    for (old, new) in names {
      move(base.appendingPathComponent(old), to: base.appendingPathComponent(new))
    }
  }

  private static func move(_ source: URL, to destination: URL) {
    let manager = FileManager.default
    guard manager.fileExists(atPath: source.path) else { return }
    guard !manager.fileExists(atPath: destination.path) else { return }
    try? manager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? manager.moveItem(at: source, to: destination)
  }

  /// UserDefaults are keyed by bundle id, so the rename would otherwise look like
  /// a fresh install (download folder, platform, quality, volume…).
  private static func migrateDefaults() {
    guard let old = UserDefaults(suiteName: oldBundleID) else { return }
    let keys = [
      "downloadDirectory", "preferredPlatform", "preferredQuality", "preferredSection",
      "embedTags", "playerVolume", "eqPreset", "lyricPanelFrame",
    ]
    let standard = UserDefaults.standard
    for key in keys where standard.object(forKey: key) == nil {
      guard let value = old.object(forKey: key) else { continue }
      standard.set(value, forKey: key)
    }
    // Point an old download path at the migrated folder.
    if let stored = standard.string(forKey: "downloadDirectory"),
       stored.contains("Music/Q Music") {
      let migrated = stored.replacingOccurrences(of: "Music/Q Music", with: "Music/Cadence")
      standard.set(migrated, forKey: "downloadDirectory")
    }
  }
}
