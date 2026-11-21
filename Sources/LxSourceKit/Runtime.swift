import CZlib
import Foundation
import JavaScriptCore

/// A host for LX 音源 scripts: JavaScriptCore + a `lx` bridge that mirrors
/// Q-music's `src/main/modules/userApi/renderer/preload.js`.
public final class LXEngine {

  let ctx: JSContext
  private let session: URLSession
  private var timers: [Int: DispatchWorkItem] = [:]
  private var tasks: [Int: URLSessionDataTask] = [:]
  private var pending = 0
  private var finished = false
  private var verbose = false

  /// What the bare JavaScriptCore context provides before any polyfill runs.
  public private(set) var engineFeatures: String?

  public var onInited: ((String) -> Void)?
  public var onResult: ((Bool, String) -> Void)?
  public var onLog: ((String) -> Void)?

  public init(verbose: Bool = false) throws {
    self.verbose = verbose
    // A private virtual machine per 音源 keeps heaps and GC separate, so
    // dropping an engine actually returns its memory.
    guard let ctx = JSContext(virtualMachine: JSVirtualMachine()) else {
      throw LxError.bridge("JSContext unavailable")
    }
    self.ctx = ctx
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: config)

    ctx.exceptionHandler = { [weak self] _, exception in
      let text = exception?.toString() ?? "<unknown>"
      self?.emit("JS EXCEPTION \(text)")
    }
    let probe = """
    JSON.stringify({
      url: typeof URL, textEncoder: typeof TextEncoder, textDecoder: typeof TextDecoder,
      atob: typeof atob, btoa: typeof btoa, fetch: typeof fetch, console: typeof console,
      setTimeout: typeof setTimeout, queueMicrotask: typeof queueMicrotask
    })
    """
    engineFeatures = ctx.evaluateScript(probe)?.toString()
    installBridge()
    try evaluate(resource: "glue")
  }

  // MARK: - setup

  private static func resourceURL(_ name: String, _ ext: String) -> URL? {
    Bundle.module.url(forResource: name, withExtension: ext)
  }

  private func evaluate(resource name: String) throws {
    guard let url = Self.resourceURL(name, "js"), let source = try? String(contentsOf: url, encoding: .utf8) else {
      throw LxError.bridge("missing resource \(name).js")
    }
    ctx.evaluateScript(source, withSourceURL: url)
    if let error = ctx.exception { throw LxError.bridge("glue failed: \(error)") }
  }

  public func evaluateSource(_ source: String, name: String) throws {
    ctx.setObject(source, forKeyedSubscript: "__lxRawScript" as NSString)
    ctx.evaluateScript(source, withSourceURL: URL(fileURLWithPath: name))
    if let error = ctx.exception { throw LxError.bridge("script failed: \(error)") }
  }

  private func installBridge() {
    guard let host = JSValue(newObjectIn: ctx) else { return }

    func setBlock(_ name: String, _ block: AnyObject) {
      host.setObject(block, forKeyedSubscript: name as NSString)
    }

    let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
      self?.emit("[\(level)] \(message)")
    }
    setBlock("log", unsafeBitCast(log, to: AnyObject.self))

    let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
    setBlock("now", unsafeBitCast(now, to: AnyObject.self))

    let schedule: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, repeatable in
      self?.scheduleTimer(id, ms: ms, repeatable: repeatable)
    }
    setBlock("scheduleTimer", unsafeBitCast(schedule, to: AnyObject.self))

    let clear: @convention(block) (Int) -> Void = { [weak self] id in
      self?.timers[id]?.cancel()
      self?.timers[id] = nil
    }
    setBlock("clearTimer", unsafeBitCast(clear, to: AnyObject.self))

    let request: @convention(block) (String, Int) -> Void = { [weak self] json, id in
      self?.startRequest(json, id: id)
    }
    setBlock("request", unsafeBitCast(request, to: AnyObject.self))

    let abort: @convention(block) (Int) -> Void = { [weak self] id in
      self?.tasks[id]?.cancel()
      self?.tasks[id] = nil
    }
    setBlock("abortRequest", unsafeBitCast(abort, to: AnyObject.self))

    let crypto: @convention(block) (String, String) -> String = { op, argsJSON in
      LXEngine.cryptoEnvelope(op: op, argsJSON: argsJSON)
    }
    setBlock("crypto", unsafeBitCast(crypto, to: AnyObject.self))

    let zlib: @convention(block) (String, String) -> String = { op, b64 in
      LXEngine.zlibEnvelope(op: op, base64: b64)
    }
    setBlock("zlib", unsafeBitCast(zlib, to: AnyObject.self))

    let inited: @convention(block) (String) -> Void = { [weak self] json in
      self?.emit("lx.send(inited) received")
      self?.handleInited(json)
    }
    setBlock("onInited", unsafeBitCast(inited, to: AnyObject.self))

    let result: @convention(block) (Bool, String) -> Void = { [weak self] ok, payload in
      self?.handleResult(ok, payload)
    }
    setBlock("onResult", unsafeBitCast(result, to: AnyObject.self))

    ctx.setObject(host, forKeyedSubscript: "__native" as NSString)
  }

  // MARK: - timers

  private func scheduleTimer(_ id: Int, ms: Double, repeatable: Bool) {
    timers[id]?.cancel()
    let delay = max(0, ms) / 1000
    if repeatable {
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.callJS("__lx_onTimer", [id])
        self.scheduleTimer(id, ms: ms, repeatable: true)
      }
      timers[id] = item
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    } else {
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.timers[id] = nil
        self.callJS("__lx_onTimer", [id])
      }
      timers[id] = item
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  // MARK: - http

  private func startRequest(_ json: String, id: Int) {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let urlString = object["url"] as? String,
          let url = URL(string: urlString) else {
      callJS("__lx_onResponse", [id, Self.errorEnvelope("invalid request config")])
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = (object["method"] as? String ?? "GET").uppercased()
    request.timeoutInterval = object["timeout"] as? Double ?? 60
    if let headers = object["headers"] as? [String: String] {
      for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    } else if let headers = object["headers"] as? [String: Any] {
      for (key, value) in headers { request.setValue("\(value)", forHTTPHeaderField: key) }
    }
    if let body = object["body"] as? String, let bytes = Data(base64Encoded: body) {
      request.httpBody = bytes
    }

    pending += 1
    record("→ \(request.httpMethod ?? "GET") \(urlString)")

    let began = Date()
    let task = session.dataTask(with: request) { [weak self] body, response, error in
      let elapsed = Date().timeIntervalSince(began)
      let payload: [String: Any]
      if let error {
        payload = ["ok": false, "error": error.localizedDescription]
      } else if let http = response as? HTTPURLResponse {
        var headers: [String: String] = [:]
        // needle surfaces Node's already-lowercased header names; match that.
        for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
        payload = [
          "ok": true,
          "statusCode": http.statusCode,
          "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
          "headers": headers,
          "url": http.url?.absoluteString ?? urlString,
          "body": (body ?? Data()).base64EncodedString(),
        ]
      } else {
        payload = ["ok": false, "error": "no response"]
      }
      let json = (try? JSONSerialization.data(withJSONObject: payload))
        .flatMap { String(data: $0, encoding: .utf8) } ?? Self.errorEnvelope("encode failed")

      DispatchQueue.main.async {
        self?.record(String(format: "← %d %.0fms %@", body?.count ?? 0, elapsed * 1000, urlString))
        self?.tasks[id] = nil
        self?.pending -= 1
        self?.callJS("__lx_onResponse", [id, json])
      }
    }
    tasks[id] = task
    task.resume()
  }

  private static func errorEnvelope(_ message: String) -> String {
    let payload: [String: Any] = ["ok": false, "error": message]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  // MARK: - crypto / zlib

  fileprivate static func cryptoEnvelope(op: String, argsJSON: String) -> String {
    do {
      let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
      let output: Data
      switch op {
      case "md5":
        let input = args["data"] as? String ?? ""
        let payload: [String: Any] = ["ok": true, "data": LxCrypto.md5Hex(input)]
        return String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
      case "randomBytes":
        output = LxCrypto.randomBytes(args["size"] as? Int ?? 16)
      case "aesEncrypt":
        guard let bytes = Data(base64Encoded: args["data"] as? String ?? ""),
              let mode = args["mode"] as? String,
              let key = Data(base64Encoded: args["key"] as? String ?? "") else {
          throw LxError.crypto("bad aes args")
        }
        let iv = (args["iv"] as? String).flatMap { Data(base64Encoded: $0) }
        output = try LxCrypto.aesEncrypt(data: bytes, mode: mode, key: key, iv: iv)
      case "rsaEncrypt":
        guard let bytes = Data(base64Encoded: args["data"] as? String ?? ""),
              let pem = args["key"] as? String else { throw LxError.crypto("bad rsa args") }
        output = try LxCrypto.rsaEncryptRaw(data: bytes, pem: pem)
      default:
        throw LxError.crypto("unknown op \(op)")
      }
      let payload: [String: Any] = ["ok": true, "data": output.base64EncodedString()]
      return String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    } catch {
      return errorEnvelope(error.localizedDescription)
    }
  }

  fileprivate static func zlibEnvelope(op: String, base64: String) -> String {
    guard let input = Data(base64Encoded: base64) else { return errorEnvelope("bad base64") }
    var out: UnsafeMutablePointer<UInt8>?
    var outLen = 0
    let status = input.withUnsafeBytes { raw -> Int32 in
      let pointer = raw.bindMemory(to: UInt8.self).baseAddress
      return op == "inflate"
        ? lx_inflate(pointer, input.count, &out, &outLen)
        : lx_deflate(pointer, input.count, &out, &outLen)
    }
    guard status == 0, let out else { return errorEnvelope("zlib error \(status)") }
    defer { lx_free(out) }
    let data = Data(bytes: out, count: outLen)
    let payload: [String: Any] = ["ok": true, "data": data.base64EncodedString()]
    return String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
  }


  // MARK: - async API

  public struct SourceEntry: Codable, Sendable {
    public let type: String
    public let actions: [String]
    public let qualitys: [String]

    public init(type: String, actions: [String], qualitys: [String]) {
      self.type = type
      self.actions = actions
      self.qualitys = qualitys
    }
  }

  public struct ScriptInfo: Codable, Sendable {
    public let name: String
    public let description: String
    public let version: String
    public let author: String
    public let homepage: String

    public init(name: String, description: String, version: String, author: String, homepage: String) {
      self.name = name
      self.description = description
      self.version = version
      self.author = author
      self.homepage = homepage
    }
  }

  private var initContinuation: CheckedContinuation<Void, Error>?
  private var resultContinuation: CheckedContinuation<[String: Any], Error>?
  private var didInit = false

  public private(set) var scriptInfo = ScriptInfo(name: "", description: "", version: "", author: "", homepage: "")
  public private(set) var sources: [String: SourceEntry] = [:]

  /// Evaluate a 音源 script and wait for its `lx.send(inited)` handshake.
  @discardableResult
  public func load(script: String, fileName: String) async throws -> [String: SourceEntry] {
    didInit = false
    sources = [:]
    try evaluateSource(script, name: fileName)
    scriptInfo = readScriptInfo()
    if didInit { return sources }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      initContinuation = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
        guard let self, let pending = self.initContinuation else { return }
        self.initContinuation = nil
        pending.resume(throwing: LxError.bridge("音源初始化超时（10s）"))
      }
    }
    return sources
  }

  /// Resolve a playable URL for one song through the loaded script.
  public func resolve(source: String, quality: String, musicInfo: [String: Any], timeout: TimeInterval = 25) async throws -> String {
    guard resultContinuation == nil else { throw LxError.bridge("上一个请求还没结束") }
    let info: [String: Any] = ["type": quality, "musicInfo": musicInfo]
    let data = try JSONSerialization.data(withJSONObject: info)
    let infoJSON = String(data: data, encoding: .utf8) ?? "{}"

    let payload: [String: Any] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
      finished = false
      resultContinuation = continuation
      invokeRequest(source: source, action: "musicUrl", infoJSON: infoJSON)
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let self, let pending = self.resultContinuation else { return }
        self.resultContinuation = nil
        pending.resume(throwing: LxError.bridge("取链超时（\(Int(timeout))s）"))
      }
    }
    guard let url = payload["url"] as? String, !url.isEmpty else {
      throw LxError.bridge("音源没有返回播放地址")
    }
    return url
  }

  private func handleInited(_ json: String) {
    didInit = true
    if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
       let raw = object["sources"] as? [String: Any] {
      var parsed: [String: SourceEntry] = [:]
      for (key, value) in raw {
        guard let entry = value as? [String: Any] else { continue }
        parsed[key] = SourceEntry(
          type: entry["type"] as? String ?? "music",
          actions: entry["actions"] as? [String] ?? [],
          qualitys: entry["qualitys"] as? [String] ?? []
        )
      }
      sources = parsed
    }
    onInited?(json)
    if let continuation = initContinuation {
      initContinuation = nil
      continuation.resume()
    }
  }

  private func handleResult(_ ok: Bool, _ payload: String) {
    finished = true
    onResult?(ok, payload)
    guard let continuation = resultContinuation else { return }
    resultContinuation = nil
    if ok, let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
      continuation.resume(returning: object)
    } else {
      continuation.resume(throwing: LxError.bridge(payload))
    }
  }

  private func readScriptInfo() -> ScriptInfo {
    guard let lx = ctx.objectForKeyedSubscript("lx"),
          let info = lx.objectForKeyedSubscript("currentScriptInfo"),
          let dictionary = info.toDictionary() as? [String: Any] else {
      return ScriptInfo(name: "", description: "", version: "", author: "", homepage: "")
    }
    return ScriptInfo(
      name: dictionary["name"] as? String ?? "",
      description: dictionary["description"] as? String ?? "",
      version: dictionary["version"] as? String ?? "",
      author: dictionary["author"] as? String ?? "",
      homepage: dictionary["homepage"] as? String ?? ""
    )
  }

  // MARK: - driving the engine
  /// Pump the run loop until `condition` holds, the request settles, or the deadline passes.
  public func spin(until deadline: Date, until condition: @escaping () -> Bool) {
    while Date() < deadline && !finished && !condition() {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }


  private func callJS(_ function: String, _ args: [Any]) {
    guard let fn = ctx.objectForKeyedSubscript(function), !fn.isUndefined else { return }
    fn.call(withArguments: args)
    if let error = ctx.exception {
      emit("JS EXCEPTION in \(function): \(error)")
      ctx.exception = nil
    }
  }

  public func invokeRequest(source: String, action: String, infoJSON: String) {
    callJS("__lx_invokeRequest", [source, action, infoJSON])
  }

  /// Pump the main run loop until the request settles or the deadline passes.
  public func spin(until deadline: Date) {
    while Date() < deadline && !finished {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  public func spinFor(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline && !finished {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  private func emit(_ message: String) {
    onLog?(message)
    if verbose { FileHandle.standardError.write(Data("    \(message)\n".utf8)) }
  }

  private func record(_ message: String) {
    if verbose { FileHandle.standardError.write(Data("    \(message)\n".utf8)) }
  }
}
