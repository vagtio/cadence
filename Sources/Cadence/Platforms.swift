import Foundation

enum Platform: String, CaseIterable, Identifiable, Sendable {
  case kg, wy, kw, tx

  var id: String { rawValue }

  /// Quality preference order understood by LX 音源 scripts.
  static let qualityOrder = ["flac24bit", "flac", "320k", "128k"]
}

enum SearchError: LocalizedError {
  case unavailable(String)
  case empty

  var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    case .empty: return "没有结果"
    }
  }
}

/// The LX 音源 protocol only resolves URLs. Search and lyrics are implemented
/// per platform here, mirroring what Q-music's `src/renderer/utils/musicSdk/*`
/// JS SDKs provide.
enum MusicSearch {

  static func search(_ keyword: String, on platform: Platform, limit: Int = 30) async throws -> [Song] {
    switch platform {
    case .kg: return try await kugou(keyword, limit: limit)
    case .wy: return try await netease(keyword, limit: limit)
    case .kw: return try await kuwo(keyword, limit: limit)
    case .tx: return try await qq(keyword, limit: limit)
    }
  }

  // MARK: - 酷狗

  private static func kugou(_ keyword: String, limit: Int) async throws -> [Song] {
    var components = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/search/song")!
    components.queryItems = [
      .init(name: "format", value: "json"),
      .init(name: "keyword", value: keyword),
      .init(name: "page", value: "1"),
      .init(name: "pagesize", value: "\(limit)"),
    ]
    let object = try await getJSON(components.url!)
    guard let data = object["data"] as? [String: Any],
          let info = data["info"] as? [[String: Any]] else { throw SearchError.empty }

    return info.compactMap { item in
      guard let hash = item["hash"] as? String, !hash.isEmpty,
            let name = item["songname"] as? String else { return nil }
      return Song(
        platform: .kg,
        key: hash,
        name: name,
        singer: item["singername"] as? String ?? "",
        album: item["album_name"] as? String ?? "",
        duration: Double(item["duration"] as? Int ?? 0),
        picture: nil,
        ids: ["hash": hash, "songmid": hash, "albumId": "\(item["album_id"] as? String ?? "")"]
      )
    }
  }

  // MARK: - 网易云

  private static func netease(_ keyword: String, limit: Int) async throws -> [Song] {
    var components = URLComponents(string: "https://music.163.com/api/search/get")!
    components.queryItems = [
      .init(name: "s", value: keyword),
      .init(name: "type", value: "1"),
      .init(name: "limit", value: "\(limit)"),
      .init(name: "offset", value: "0"),
    ]
    let object = try await getJSON(components.url!, referer: "https://music.163.com/")
    guard let result = object["result"] as? [String: Any],
          let songs = result["songs"] as? [[String: Any]] else { throw SearchError.empty }

    return songs.compactMap { item in
      guard let identifier = item["id"] as? Int, let name = item["name"] as? String else { return nil }
      let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
      let album = item["album"] as? [String: Any]
      return Song(
        platform: .wy,
        key: "\(identifier)",
        name: name,
        singer: artists.joined(separator: "/"),
        album: album?["name"] as? String ?? "",
        duration: Double(item["duration"] as? Int ?? 0) / 1000,
        picture: album?["picUrl"] as? String,
        ids: [
          "songmid": "\(identifier)",
          "songId": "\(identifier)",
          "albumId": "\(album?["id"] as? Int ?? 0)",
        ]
      )
    }
  }

  // MARK: - 酷我

  private static func kuwo(_ keyword: String, limit: Int) async throws -> [Song] {
    var components = URLComponents(string: "http://search.kuwo.cn/r.s")!
    components.queryItems = [
      .init(name: "all", value: keyword),
      .init(name: "ft", value: "music"),
      .init(name: "itemset", value: "web_2013"),
      .init(name: "client", value: "kt"),
      .init(name: "pn", value: "0"),
      .init(name: "rn", value: "\(limit)"),
      .init(name: "rformat", value: "json"),
      .init(name: "encoding", value: "utf8"),
    ]
    let raw = try await getText(components.url!)

    // Kuwo answers with a single-quoted JS literal, not JSON. Each entry is a
    // `{...}` block; MUSICRID identifies it.
    var songs: [Song] = []
    for block in raw.components(separatedBy: "},{") where block.contains("'MUSICRID'") {
      guard let rid = field("MUSICRID", in: block)?.replacingOccurrences(of: "MUSIC_", with: ""),
            let name = field("SONGNAME", in: block) else { continue }
      songs.append(Song(
        platform: .kw,
        key: rid,
        name: clean(name),
        singer: clean(field("ARTIST", in: block) ?? ""),
        album: clean(field("ALBUM", in: block) ?? ""),
        duration: Double(field("DURATION", in: block) ?? "") ?? 0,
        picture: nil,
        ids: ["rid": rid, "songmid": rid]
      ))
      if songs.count >= limit { break }
    }
    guard !songs.isEmpty else { throw SearchError.empty }
    return songs
  }

  private static func field(_ key: String, in block: String) -> String? {
    let pattern = "'" + key + "':'([^']*)'"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(block.startIndex..., in: block)
    guard let match = regex.firstMatch(in: block, range: range),
          let valueRange = Range(match.range(at: 1), in: block) else { return nil }
    return String(block[valueRange])
  }

  private static func clean(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  // MARK: - QQ 音乐

  private static func qq(_ keyword: String, limit: Int) async throws -> [Song] {
    // The full search API needs signed cookies; the smartbox endpoint is the
    // only one that answers anonymously, and it caps at a handful of results.
    var components = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
    components.queryItems = [
      .init(name: "key", value: keyword),
      .init(name: "format", value: "json"),
    ]
    let object = try await getJSON(components.url!, referer: "https://y.qq.com/")
    guard let data = object["data"] as? [String: Any],
          let songs = (data["song"] as? [String: Any])?["itemlist"] as? [[String: Any]] else {
      throw SearchError.empty
    }

    return songs.prefix(limit).compactMap { item in
      guard let mid = item["mid"] as? String, let name = item["name"] as? String else { return nil }
      return Song(
        platform: .tx,
        key: mid,
        name: name,
        singer: item["singer"] as? String ?? "",
        album: "",
        duration: 0,
        picture: nil,
        ids: ["songmid": mid, "strMediaMid": mid, "songId": item["docid"] as? String ?? ""]
      )
    }
  }

  // MARK: - transport

  private static func getText(_ url: URL, referer: String? = nil) async throws -> String {
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
    if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw SearchError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func getJSON(_ url: URL, referer: String? = nil) async throws -> [String: Any] {
    let text = try await getText(url, referer: referer)
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
      throw SearchError.unavailable("响应不是 JSON")
    }
    return object
  }
}

enum LyricsAPI {
  /// Raw LRC text (plus an optional translation track) — used both for display and
  /// for writing into the downloaded file.
  struct Raw {
    let main: String
    let translation: String
  }

  static func fetchRaw(for song: Song) async throws -> Raw {
    if let native = try? await nativeRaw(song), !native.main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return native
    }
    // Cross-source fallback: 酷我 publishes no lyric API, and any source can miss.
    if let fallback = try? await crossSource(song) { return fallback }
    throw SearchError.unavailable("没有找到歌词")
  }

  private static func nativeRaw(_ song: Song) async throws -> Raw {
    switch song.platform {
    case .kg: return try await kugouRaw(song)
    case .wy: return try await neteaseRaw(song)
    case .tx: return try await qqRaw(song)
    case .kw: throw SearchError.unavailable("酷我歌词接口不可用")
    }
  }

  /// Matches the track on 网易云 by name + artist and takes that lyric.
  private static func crossSource(_ song: Song) async throws -> Raw {
    let query = song.singer.isEmpty ? song.name : "\(song.name) \(song.singer)"
    guard let match = try await MusicSearch.search(query, on: .wy, limit: 1).first else {
      throw SearchError.empty
    }
    return try await neteaseRaw(match)
  }

  static func fetch(for song: Song) async throws -> [LyricLine] {
    let raw = try await fetchRaw(for: song)
    return LRC.merge(LRC.parse(raw.main), with: LRC.parse(raw.translation))
  }

  private static func kugouRaw(_ song: Song) async throws -> Raw {
    var search = URLComponents(string: "https://krcs.kugou.com/search")!
    search.queryItems = [
      .init(name: "ver", value: "1"), .init(name: "man", value: "yes"), .init(name: "client", value: "mobi"),
      .init(name: "keyword", value: ""), .init(name: "duration", value: ""), .init(name: "hash", value: song.key),
    ]
    let candidates = try await get([String: Any].self, search.url!)
    guard let list = candidates["candidates"] as? [[String: Any]],
          let first = list.first,
          let id = first["id"] as? String,
          let accesskey = first["accesskey"] as? String else { throw SearchError.empty }

    var download = URLComponents(string: "https://lyrics.kugou.com/download")!
    download.queryItems = [
      .init(name: "ver", value: "1"), .init(name: "client", value: "pc"), .init(name: "id", value: id),
      .init(name: "accesskey", value: accesskey), .init(name: "fmt", value: "lrc"), .init(name: "charset", value: "utf8"),
    ]
    let payload = try await get([String: Any].self, download.url!)
    guard let encoded = payload["content"] as? String,
          let data = Data(base64Encoded: encoded),
          let text = String(data: data, encoding: .utf8) else { throw SearchError.empty }
    return Raw(main: text, translation: "")
  }

  private static func neteaseRaw(_ song: Song) async throws -> Raw {
    var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
    components.queryItems = [
      .init(name: "id", value: song.key), .init(name: "lv", value: "-1"),
      .init(name: "kv", value: "-1"), .init(name: "tv", value: "-1"),
    ]
    let payload = try await get([String: Any].self, components.url!, referer: "https://music.163.com/")
    let main = (payload["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
    let translation = (payload["tlyric"] as? [String: Any])?["lyric"] as? String ?? ""
    return Raw(main: main, translation: translation)
  }

  private static func qqRaw(_ song: Song) async throws -> Raw {
    var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
    components.queryItems = [
      .init(name: "songmid", value: song.key), .init(name: "format", value: "json"),
      .init(name: "nobase64", value: "1"), .init(name: "g_tk", value: "5381"),
    ]
    let payload = try await get([String: Any].self, components.url!, referer: "https://y.qq.com/")
    guard let lyric = payload["lyric"] as? String, !lyric.isEmpty else { throw SearchError.empty }
    return Raw(main: lyric, translation: payload["trans"] as? String ?? "")
  }

  private static func get<T>(_ type: T.Type, _ url: URL, referer: String? = nil) async throws -> T {
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
    if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
    let (data, _) = try await URLSession.shared.data(for: request)
    guard let object = try JSONSerialization.jsonObject(with: data) as? T else { throw SearchError.empty }
    return object
  }
}


/// Album art. Prefers a single cheap request per platform:
/// 鲸 → `album/info`, 焰 → `song/detail`; 珀/萤 fall back to matching on 焰.
enum CoverAPI {
  static func coverURL(for song: Song, size: Int = 300) async -> URL? {
    switch song.platform {
    case .wy:
      return await neteaseURL(id: song.key, size: size)
    case .kg:
      if let albumId = song.ids["albumId"], !albumId.isEmpty, albumId != "0",
         let url = await kugouURL(albumId: albumId, size: size) {
        return url
      }
      return await matchedURL(song, size: size)
    case .kw, .tx:
      return await matchedURL(song, size: size)
    }
  }

  static func coverData(for song: Song, size: Int = 500) async -> Data? {
    if let picture = song.picture, let url = URL(string: picture) {
      let scaled = URL(string: picture + "?param=\(size)y\(size)") ?? url
      if let data = await fetch(scaled) { return data }
      if let data = await fetch(url) { return data }
    }
    guard let url = await coverURL(for: song, size: size) else { return nil }
    return await fetch(url)
  }

  // MARK: - per platform

  private static func kugouURL(albumId: String, size: Int) async -> URL? {
    guard let url = URL(string: "http://mobilecdn.kugou.com/api/v3/album/info?albumid=\(albumId)"),
          let payload = await fetchJSON(url),
          let data = payload["data"] as? [String: Any],
          let template = data["imgurl"] as? String else { return nil }
    let replaced = template.replacingOccurrences(of: "{size}", with: "\(size)")
    return URL(string: replaced)
  }

  private static func neteaseURL(id: String, size: Int) async -> URL? {
    guard let url = URL(string: "https://music.163.com/api/song/detail?ids=%5B\(id)%5D"),
          let payload = await fetchJSON(url),
          let songs = payload["songs"] as? [[String: Any]],
          let album = songs.first?["album"] as? [String: Any],
          let picture = album["picUrl"] as? String else { return nil }
    return URL(string: picture + "?param=\(size)y\(size)")
  }

  private static func matchedURL(_ song: Song, size: Int) async -> URL? {
    let query = song.singer.isEmpty ? song.name : "\(song.name) \(song.singer)"
    guard let match = try? await MusicSearch.search(query, on: .wy, limit: 1).first else { return nil }
    return await neteaseURL(id: match.key, size: size)
  }

  // MARK: - transport

  private static func fetchJSON(_ url: URL) async -> [String: Any]? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func fetch(_ url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          data.count > 512 else { return nil }
    return data
  }
}
