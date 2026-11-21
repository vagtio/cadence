import Foundation

/// Writes cover + lyrics into the downloaded file.
///
/// MP3 gets a real ID3v2.3 tag (UTF-16 text frames, APIC cover, USLT lyrics) so the
/// album art and lyrics travel inside the single file. FLAC/M4A are left untouched —
/// the caller writes `.lrc` / `.jpg` sidecars next to them instead.
enum MetadataWriter {

  struct Tags {
    let title: String
    let artist: String
    let album: String
    let lyrics: String?
    let cover: Data?
    let coverMime: String
  }

  /// Returns true when the tags were embedded into the file itself.
  @discardableResult
  static func embed(_ tags: Tags, into file: URL) -> Bool {
    guard file.pathExtension.lowercased() == "mp3" else { return false }
    guard let data = try? Data(contentsOf: file) else { return false }

    var frames = Data()
    if !tags.title.isEmpty { frames.append(textFrame("TIT2", tags.title)) }
    if !tags.artist.isEmpty { frames.append(textFrame("TPE1", tags.artist)) }
    if !tags.album.isEmpty { frames.append(textFrame("TALB", tags.album)) }
    if let lyrics = tags.lyrics, !lyrics.isEmpty { frames.append(lyricsFrame(lyrics)) }
    if let cover = tags.cover, !cover.isEmpty { frames.append(coverFrame(cover, mime: tags.coverMime)) }
    guard !frames.isEmpty else { return false }

    var tag = Data("ID3".utf8)
    tag.append(contentsOf: [0x03, 0x00, 0x00])       // v2.3, revision 0, no flags
    tag.append(synchsafe(frames.count))
    tag.append(frames)

    var output = tag
    output.append(stripExistingTag(data))
    return (try? output.write(to: file, options: .atomic)) != nil
  }

  /// FLAC/M4A path: keep the audio as-is and put the extras beside it.
  @discardableResult
  static func writeSidecars(_ tags: Tags, beside audioFile: URL) -> Bool {
    let base = audioFile.deletingPathExtension()
    var wrote = false
    if let lyrics = tags.lyrics, !lyrics.isEmpty {
      try? Data(lyrics.utf8).write(to: base.appendingPathExtension("lrc"))
      wrote = true
    }
    if let cover = tags.cover, !cover.isEmpty {
      let ext = tags.coverMime.contains("png") ? "png" : "jpg"
      try? cover.write(to: base.appendingPathExtension(ext))
      wrote = true
    }
    return wrote
  }

  // MARK: - ID3v2.3 internals

  private static func textFrame(_ id: String, _ value: String) -> Data {
    var payload = Data([0x01])                      // UTF-16 with BOM
    payload.append(utf16(value))
    return frame(id, payload)
  }

  private static func lyricsFrame(_ lyrics: String) -> Data {
    var payload = Data([0x01])                      // encoding
    payload.append(Data("chi".utf8))                // language
    payload.append(utf16(""))                       // empty content descriptor
    payload.append(utf16(lyrics))
    return frame("USLT", payload)
  }

  private static func coverFrame(_ image: Data, mime: String) -> Data {
    var payload = Data([0x00])                      // latin-1 for mime/description
    payload.append(Data(mime.utf8))
    payload.append(0x00)
    payload.append(0x03)                            // picture type: front cover
    payload.append(0x00)                            // empty description
    payload.append(image)
    return frame("APIC", payload)
  }

  private static func frame(_ id: String, _ payload: Data) -> Data {
    var data = Data(id.utf8)
    data.append(bigEndian32(payload.count))
    data.append(contentsOf: [0x00, 0x00])           // frame flags
    data.append(payload)
    return data
  }

  private static func utf16(_ value: String) -> Data {
    var data = Data([0xFF, 0xFE])                   // BOM, little endian
    for unit in value.utf16 {
      data.append(UInt8(unit & 0xFF))
      data.append(UInt8(unit >> 8))
    }
    data.append(contentsOf: [0x00, 0x00])           // terminator
    return data
  }

  private static func bigEndian32(_ value: Int) -> Data {
    let v = UInt32(clamping: value)
    return Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
  }

  /// The tag header length field is synchsafe in every ID3v2 version.
  private static func synchsafe(_ value: Int) -> Data {
    let v = UInt32(clamping: value)
    return Data([
      UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F),
      UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F),
    ])
  }

  private static func decodeSynchsafe(_ bytes: Data) -> Int {
    let slice = [UInt8](bytes.prefix(4))
    guard slice.count == 4 else { return 0 }
    return (Int(slice[0] & 0x7F) << 21) | (Int(slice[1] & 0x7F) << 14)
      | (Int(slice[2] & 0x7F) << 7) | Int(slice[3] & 0x7F)
  }

  /// Drops an existing ID3v2 tag so re-downloading never stacks tags.
  private static func stripExistingTag(_ data: Data) -> Data {
    guard data.count > 10, data.starts(with: Data("ID3".utf8)) else { return data }
    let size = decodeSynchsafe(data.subdata(in: 6..<10))
    let total = 10 + size
    guard total > 0, total < data.count else { return data }
    return data.subdata(in: total..<data.count)
  }
}
