import Foundation

struct Song: Identifiable, Hashable {
  let platform: Platform
  /// Platform-native identifier: kg hash / wy id / kw rid / tx mid.
  let key: String
  let name: String
  let singer: String
  let album: String
  let duration: Double
  let picture: String?
  /// Extra id fields some 音源 scripts read (hash / rid / strMediaMid / copyrightId…).
  let ids: [String: String]

  var id: String { "\(platform.rawValue)-\(key)" }

  var durationText: String {
    guard duration > 0 else { return "--:--" }
    let total = Int(duration.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// Shape Q-music hands to 音源 scripts (`toOldMusicInfo` in
  /// `src/common/utils/tools.ts`).
  var musicInfo: [String: Any] {
    var info: [String: Any] = [
      "name": name,
      "singer": singer,
      "source": platform.rawValue,
      "songmid": ids["songmid"] ?? key,
      "interval": durationText == "--:--" ? "" : durationText,
      "albumName": album,
      "albumId": ids["albumId"] ?? "",
      "img": picture ?? "",
      "typeUrl": [:] as [String: Any],
      "types": [] as [[String: Any]],
      "_types": [:] as [String: Any],
    ]
    for (key, value) in ids { info[key] = value }
    return info
  }

  var fileBaseName: String {
    let raw = singer.isEmpty ? name : "\(singer) - \(name)"
    return raw
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
      .trimmingCharacters(in: .whitespaces)
  }
}

struct LyricLine: Identifiable, Hashable {
  let id = UUID()
  let time: TimeInterval
  let text: String
}

enum LRC {
  /// Parses LRC with multiple timestamps per line and folds bilingual lines that
  /// share a timestamp into one entry (two rows in the panel, like Q-music).
  static func parse(_ raw: String) -> [LyricLine] {
    let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    var buckets: [Int: [String]] = [:]

    // Swift treats "\r\n" as one Character, so split(separator: "\n") cannot
    // break CRLF lyrics (Kugou serves CRLF + BOM) — normalise first.
    let normalised = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let text = normalised.hasPrefix("\u{FEFF}") ? String(normalised.dropFirst()) : normalised

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      let ns = trimmed as NSString
      let matches = timestamp.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
      guard !matches.isEmpty else { continue }

      let body = timestamp
        .stringByReplacingMatches(in: trimmed, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
      guard !body.isEmpty else { continue }

      for match in matches {
        guard let minutes = Int(ns.substring(with: match.range(at: 1))),
              let seconds = Int(ns.substring(with: match.range(at: 2))) else { continue }
        var fraction = 0.0
        if match.range(at: 3).location != NSNotFound {
          let digits = ns.substring(with: match.range(at: 3))
          fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
        }
        let key = Int(((Double(minutes) * 60 + Double(seconds) + fraction) * 1000).rounded())
        buckets[key, default: []].append(body)
      }
    }

    return buckets
      .sorted { $0.key < $1.key }
      .map { LyricLine(time: Double($0.key) / 1000, text: $0.value.joined(separator: "\n")) }
  }

  /// Attach a translation/romanisation track: lines sharing a timestamp become
  /// one entry with two rows.
  static func merge(_ lines: [LyricLine], with extra: [LyricLine]) -> [LyricLine] {
    guard !extra.isEmpty else { return lines }
    let extraByTime = Dictionary(extra.map { (Int(($0.time * 1000).rounded()), $0.text) }) { first, _ in first }
    return lines.map { line in
      guard let translated = extraByTime[Int((line.time * 1000).rounded())],
            !line.text.contains(translated) else { return line }
      return LyricLine(time: line.time, text: line.text + "\n" + translated)
    }
  }

  /// Renders lines back to LRC text (used when embedding lyrics into a file).
  static func serialize(_ lines: [LyricLine]) -> String {
    lines.map { line in
      let total = Int((line.time * 100).rounded())
      let text = line.text.replacingOccurrences(of: "\n", with: "\n[dup]")
      return String(format: "[%02d:%02d.%02d]%@", total / 6000, (total / 100) % 60, total % 100, text)
    }
    .joined(separator: "\n")
  }

  static func currentIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
    guard !lines.isEmpty, time >= lines[0].time else { return nil }
    var low = 0
    var high = lines.count - 1
    var answer = 0
    while low <= high {
      let mid = (low + high) / 2
      if lines[mid].time <= time {
        answer = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return answer
  }
}
