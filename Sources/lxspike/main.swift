import Foundation
import JavaScriptCore
import LxSourceKit

// MARK: - process metrics

struct ProcessMetrics {
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
}

// MARK: - options

struct Options {
  var scriptPath = ""
  var source = "kg"
  var action = "musicUrl"
  var quality = "320k"
  var timeout: TimeInterval = 30
  var verbose = false
  var verifyAudio = true
  var initOnly = false
  var musicInfo = ""

  static func parse(_ args: [String]) -> Options? {
    var options = Options()
    var index = 1
    guard args.count > 1 else { return nil }
    options.scriptPath = args[1]
    index = 2
    while index < args.count {
      let arg = args[index]
      func next() -> String? {
        guard index + 1 < args.count else { return nil }
        index += 1
        return args[index]
      }
      switch arg {
      case "--source": options.source = next() ?? options.source
      case "--action": options.action = next() ?? options.action
      case "--quality": options.quality = next() ?? options.quality
      case "--timeout": options.timeout = Double(next() ?? "") ?? options.timeout
      case "--musicinfo": options.musicInfo = next() ?? ""
      case "--verbose", "-v": options.verbose = true
      case "--no-verify": options.verifyAudio = false
      case "--init-only": options.initOnly = true
      default:
        FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
        return nil
      }
      index += 1
    }
    return options
  }
}

// MARK: - audio sniffing

func audioKind(_ data: Data) -> String? {
  let bytes = [UInt8](data.prefix(16))
  guard bytes.count >= 4 else { return nil }
  if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return "mp3 (ID3)" }
  if bytes[0] == 0xFF, bytes.count >= 2, (bytes[1] & 0xE0) == 0xE0 { return "mpeg audio" }
  if bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return "flac" }
  if bytes.count >= 4, bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { return "ogg" }
  if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 { return "wav" }
  if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "mp4/m4a" }
  return nil
}

func probeAudio(urlString: String) -> String {
  guard let url = URL(string: urlString) else { return "invalid url" }
  var request = URLRequest(url: url)
  request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
  request.timeoutInterval = 15
  let semaphore = DispatchSemaphore(value: 0)
  var outcome = "no response"
  var totalSize: Int64 = -1
  let task = URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }
    if let error {
      outcome = "error: \(error.localizedDescription)"
      return
    }
    guard let http = response as? HTTPURLResponse else { return }
    totalSize = http.expectedContentLength
    if let range = http.value(forHTTPHeaderField: "Content-Range"),
       let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
      totalSize = total
    }
    let type = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
    if let data, let kind = audioKind(data) {
      outcome = "audio ok: \(kind), \(type), \(totalSize > 0 ? "\(totalSize / 1024) KB" : "size ?")"
    } else if let data {
      outcome = "not audio (\(data.count) bytes, \(type)): \(String(decoding: data.prefix(16), as: UTF8.self).debugDescription)"
    }
  }
  task.resume()
  _ = semaphore.wait(timeout: .now() + 20)
  return outcome
}

// MARK: - main

let started = Date()
var timeline: [(String, Double)] = []
func mark(_ label: String) {
  timeline.append((label, Date().timeIntervalSince(started) * 1000))
}

guard let options = Options.parse(CommandLine.arguments) else {
  print("""
  usage: lxspike <source-script.js> [--source kg] [--quality 320k] [--action musicUrl] [--verbose]

    runs an unmodified LX 音源 script inside JavaScriptCore against the same
    `lx` surface Q-music exposes, then resolves a playable music URL.
  """)
  exit(2)
}

let scriptURL = URL(fileURLWithPath: options.scriptPath)
guard let scriptSource = try? String(contentsOf: scriptURL, encoding: .utf8) else {
  print("cannot read script: \(options.scriptPath)")
  exit(2)
}
mark("process start")

let runtime: LXEngine
do {
  runtime = try LXEngine(verbose: options.verbose)
} catch {
  print("runtime init failed: \(error.localizedDescription)")
  exit(1)
}
mark("JSC + glue ready")

var initedJSON: String?
runtime.onInited = { initedJSON = $0 }
runtime.onLog = { message in if options.verbose { print("    js: \(message)") } }

do {
  try runtime.evaluateSource(scriptSource, name: scriptURL.lastPathComponent)
} catch {
  print("script failed to load: \(error.localizedDescription)")
  exit(1)
}
mark("script evaluated")

runtime.spin(until: Date().addingTimeInterval(3), until: { initedJSON != nil })
mark("lx.send(inited)")

guard let initedJSON,
      let inited = try? JSONSerialization.jsonObject(with: Data(initedJSON.utf8)) as? [String: Any],
      let sources = inited["sources"] as? [String: Any] else {
  print("script did not call lx.send(EVENT_NAMES.inited)")
  exit(1)
}

if options.initOnly {
  let names = sources.keys.sorted().joined(separator: ",")
  print("init ok: \(names.isEmpty ? "(no sources)" : names)  \(Int(timeline.last?.1 ?? 0)) ms")
  exit(sources.isEmpty ? 1 : 0)
}

let musicInfo = options.musicInfo.isEmpty
  ? """
  {"source":"\(options.source)","songmid":"0039MnYb0qxYhV","hash":"\(String(repeating: "A1B2C3D4E5F6", count: 2))","name":"测试","singer":"spike","interval":"03:20"}
  """
  : options.musicInfo

let infoJSON = """
{"type":"\(options.quality)","musicInfo":\(musicInfo)}
"""

var resultURL: String?
var resultError: String?
runtime.onResult = { ok, payload in
  if ok {
    if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
      resultURL = object["url"] as? String ?? object["data"] as? String
    }
  } else {
    resultError = payload
  }
}

if !sources.isEmpty {
  let sourceNames = sources.keys.sorted().joined(separator: ",")
  print("inited: sources=\(sourceNames)")
  if let entry = sources[options.source] as? [String: Any] {
    print("  \(options.source): actions=\((entry["actions"] as? [String])?.joined(separator: ",") ?? "-") qualitys=\((entry["qualitys"] as? [String])?.joined(separator: ",") ?? "-")")
  }
}

let requestStarted = Date()
runtime.invokeRequest(source: options.source, action: options.action, infoJSON: infoJSON)
runtime.spin(until: Date().addingTimeInterval(options.timeout))
let requestElapsed = Date().timeIntervalSince(requestStarted) * 1000
mark("musicUrl settled")

var verification = "skipped"
if let resultURL, options.verifyAudio {
  verification = probeAudio(urlString: resultURL)
}

// MARK: - report

print("")
print("─ result " + String(repeating: "─", count: 52))
if let resultURL {
  print("  url      \(resultURL.prefix(120))")
  print("  probe    \(verification)")
} else {
  print("  url      (none)")
  print("  error    \(resultError ?? "timed out after \(Int(options.timeout))s")")
}
print("  resolve  \(Int(requestElapsed)) ms")
print("  rss      \(String(format: "%.1f", ProcessMetrics.residentMB())) MB")
print("")
print("─ timeline " + String(repeating: "─", count: 50))
for (label, ms) in timeline {
  print(String(format: "  %7.1f ms  %@", ms, label))
}
print("")
if let features = runtime.engineFeatures {
  print("  JSC builtins: \(features)")
}
print("")
exit(resultURL == nil ? 1 : 0)
