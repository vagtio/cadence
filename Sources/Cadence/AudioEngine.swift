import AVFoundation
import Foundation
import OSLog

/// Progressive ("start before the download finishes") playback:
///
///   HTTP data task ──append──▶ temp file ──AVAudioFile.read──▶ PCM ──schedule──▶ playerNode
///                                                                                 │
///                                                        10-band EQ ─▶ time-pitch ─▶ mixer
///
/// A whole-file `AVAudioFile` snapshot cannot be used here: it caches the length
/// when opened. Instead a background loop reopens the file, reads the chunk that
/// arrived since the last schedule, and queues it as a PCM buffer. Buffers are
/// queued several seconds ahead, so reopens never gap the output.
final class AudioEngine: NSObject, ObservableObject {

  @Published private(set) var isPlaying = false
  @Published private(set) var isLoading = false
  @Published private(set) var isBuffering = false
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var position: TimeInterval = 0
  @Published private(set) var progress: Double = 0
  @Published var volume: Float = (UserDefaults.standard.object(forKey: "playerVolume") as? Float) ?? 0.85 {
    didSet {
      playerNode.volume = volume
      UserDefaults.standard.set(volume, forKey: "playerVolume")
    }
  }
  @Published var rate: Float = 1.0 {
    didSet { timePitch.rate = max(0.5, min(2.0, rate)) }
  }
  @Published var preset: EQPreset = EQPreset(
    rawValue: UserDefaults.standard.string(forKey: "eqPreset") ?? ""
  ) ?? .flat {
    didSet {
      applyPreset()
      UserDefaults.standard.set(preset.rawValue, forKey: "eqPreset")
    }
  }

  enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "平直", pop = "流行", rock = "摇滚", vocal = "人声", bass = "低频增强"
    var id: String { rawValue }
  }

  // MARK: - graph

  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let eq = AVAudioUnitEQ(numberOfBands: 10)
  private let timePitch = AVAudioUnitTimePitch()
  private var graphFormat: AVAudioFormat?

  // MARK: - streaming state

  private var download: ProgressiveDownload?
  private var fileURL: URL?
  private var fileComplete = false
  private var streamSampleRate: Double = 44_100
  private var nextFrame: AVAudioFramePosition = 0
  private var scheduledFrames: AVAudioFramePosition = 0
  private var running = false
  private var eofReached = false
  private let stateLock = NSLock()

  private let readQueue = DispatchQueue(label: "dev.cadence.player.read", qos: .userInitiated)
  private var timer: Timer?
  private var loadTask: Task<Void, Never>?

  /// Start playing after this much of the track has landed on disk.
  private let startThresholdBytes: Int64 = 512 * 1024
  private let chunkSeconds: Double = 10
  private let targetBufferSeconds: Double = 8

  private static let log = Logger(subsystem: "dev.cadence.player", category: "audio")

  override init() {
    Migration.runIfNeeded()
    super.init()
    engine.attach(playerNode)
    engine.attach(eq)
    engine.attach(timePitch)
    configureBands()
    applyPreset()
    playerNode.volume = volume
    // The graph is (re)connected for the first file's format in prepareGraph.
  }

  // MARK: - public API

  func play(url: URL, title: String) {
    loadTask?.cancel()
    reset()
    isLoading = true
    isBuffering = true
    position = 0
    duration = 0
    progress = 0

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("qmusic-stream-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)")
    let downloader = ProgressiveDownload(url: url, destination: destination)
    download = downloader
    fileURL = destination
    fileComplete = false
    downloader.start()

    loadTask = Task { [weak self] in
      guard let self else { return }
      // Wait for enough bytes to decode a chunk, but never longer than a timeout.
      let deadline = Date().addingTimeInterval(20)
      while !Task.isCancelled {
        let written = downloader.bytesWritten
        let total = downloader.expectedBytes
        await MainActor.run {
          if total > 0 { self.progress = min(0.99, Double(written) / Double(total)) }
        }
        if written >= self.startThresholdBytes || downloader.isComplete || Date() > deadline { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      guard !Task.isCancelled else { return }
      await self.beginPlayback()
    }
  }

  /// Play an already-downloaded local file (same read loop, no network).
  func playFile(_ url: URL, title: String) {
    loadTask?.cancel()
    reset()
    fileURL = url
    fileComplete = true
    progress = 1
    isLoading = false
    Task { await beginPlayback() }
  }

  @MainActor
  func toggle() {
    guard fileURL != nil else { return }
    if isPlaying {
      playerNode.pause()
      isPlaying = false
      stopTicking()
    } else {
      ensureEngineRunning()
      playerNode.play()
      isPlaying = true
      startTicking()
    }
  }

  /// Seeks anywhere in the track. Beyond the buffered region the read loop stalls
  /// until the download reaches that offset, so the UI shows the buffering state.
  @MainActor
  func seek(to time: TimeInterval) {
    guard fileURL != nil else { return }
    let target = max(0, min(time, duration > 0 ? duration : time))
    let wasPlaying = isPlaying
    playerNode.stop()
    stateLock.lock()
    scheduledFrames = 0
    nextFrame = AVAudioFramePosition(target * streamSampleRate)
    stateLock.unlock()
    eofReached = false
    position = target
    isPlaying = false
    if wasPlaying {
      ensureEngineRunning()
      playerNode.play()
      isPlaying = true
      startTicking()
    }
  }

  var bufferedThrough: TimeInterval {
    min(duration, Double(nextFrame) / streamSampleRate)
  }

  func stop() {
    reset()
  }

  /// Called when playback has been idle for a while: keeps the graph ready but
  /// releases the render thread and its buffers.
  func suspendIfIdle() {
    guard !isPlaying, playerNode.isPlaying == false else { return }
    if engine.isRunning {
      engine.pause()
      engine.stop()
    }
  }

  // MARK: - setup

  private func reset() {
    running = false
    eofReached = false
    loadTask?.cancel()
    loadTask = nil
    download?.cancel()
    download = nil
    playerNode.stop()
    stopTicking()
    isPlaying = false
    isLoading = false
    isBuffering = false
    if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    fileURL = nil
    fileComplete = false
    stateLock.lock()
    nextFrame = 0
    scheduledFrames = 0
    stateLock.unlock()
  }

  private func prepareGraph(for format: AVAudioFormat) -> Bool {
    if let current = graphFormat, current.sampleRate == format.sampleRate, current.channelCount == format.channelCount {
      return true
    }
    engine.stop()
    engine.disconnectNodeOutput(playerNode)
    engine.disconnectNodeOutput(eq)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(playerNode, to: eq, format: format)
    engine.connect(eq, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    graphFormat = format
    return ensureEngineRunning()
  }

  @discardableResult
  private func ensureEngineRunning() -> Bool {
    if engine.isRunning { return true }
    do {
      try engine.start()
      return true
    } catch {
      Self.log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private static let bands: [(frequency: Float, bandwidth: Float)] = [
    (32, 50), (64, 60), (125, 70), (250, 80), (500, 90),
    (1_000, 100), (2_000, 120), (4_000, 140), (8_000, 160), (16_000, 180),
  ]

  private func configureBands() {
    for (index, band) in Self.bands.enumerated() where index < eq.bands.count {
      let filter = eq.bands[index]
      filter.filterType = .parametric
      filter.frequency = band.frequency
      filter.bandwidth = band.bandwidth
      filter.gain = 0
      filter.bypass = false
    }
    eq.globalGain = 0
  }

  private func applyPreset() {
    let gains: [Float]
    switch preset {
    case .flat: gains = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    case .pop: gains = [-1, 0, 2, 3, 3, 2, 0, -1, -1, -1]
    case .rock: gains = [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]
    case .vocal: gains = [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]
    case .bass: gains = [7, 5, 3, 1, 0, 0, 0, 0, 0, 0]
    }
    for (index, value) in gains.enumerated() where index < eq.bands.count {
      eq.bands[index].gain = value
    }
  }

  // MARK: - playback start

  @MainActor
  private func beginPlayback() async {
    guard let fileURL else { return }

    // Wait until the file parses into a real audio format before building the graph.
    var audioFile: AVAudioFile?
    let parseDeadline = Date().addingTimeInterval(fileComplete ? 5 : 15)
    while audioFile == nil {
      audioFile = try? AVAudioFile(forReading: fileURL)
      if audioFile != nil { break }
      if Date() > parseDeadline { break }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let audioFile else {
      isLoading = false
      isBuffering = false
      Self.log.error("cannot parse audio stream")
      return
    }

    streamSampleRate = audioFile.processingFormat.sampleRate
    updateDurationEstimate(fileLength: audioFile.length, complete: fileComplete)
    guard prepareGraph(for: audioFile.processingFormat) else {
      isLoading = false
      isBuffering = false
      return
    }

    running = true
    eofReached = false
    readQueue.async { [weak self] in self?.readLoop() }

    // Give the read loop a moment to queue the first buffers, then start the node.
    let startDeadline = Date().addingTimeInterval(fileComplete ? 5 : 10)
    while scheduledFrameCount == 0 && Date() < startDeadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    guard scheduledFrameCount > 0 else {
      isLoading = false
      return
    }
    playerNode.play()
    isPlaying = true
    isLoading = false
    isBuffering = false
    startTicking()
  }

  private func updateDurationEstimate(fileLength: AVAudioFramePosition, complete: Bool) {
    guard streamSampleRate > 0, fileLength > 0 else { return }
    let estimate = Double(fileLength) / streamSampleRate
    DispatchQueue.main.async {
      if complete || estimate > self.duration {
        self.duration = max(self.duration, estimate)
      }
    }
  }

  private var scheduledFrameCount: AVAudioFramePosition {
    stateLock.lock(); defer { stateLock.unlock() }
    return scheduledFrames
  }

  // MARK: - read loop

  private func readLoop() {
    while running {
      guard let fileURL else { break }
      let downloader = download
      let complete = fileComplete || downloader?.isComplete == true
      let buffered = bufferedSeconds()

      if buffered >= targetBufferSeconds {
        usleep(60_000)
        continue
      }

      guard let file = try? AVAudioFile(forReading: fileURL) else {
        usleep(120_000)
        continue
      }
      downloader.map { updateDurationEstimate(fileLength: file.length, complete: $0.isComplete) }

      guard nextFrame < file.length else {
        if complete {
          eofReached = true
          usleep(120_000)
          continue
        }
        usleep(80_000)
        continue
      }

      stateLock.lock()
      let start = nextFrame
      stateLock.unlock()

      let remaining = file.length - start
      let chunkFrames = AVAudioFramePosition(chunkSeconds * streamSampleRate * Double(rate))
      let want = AVAudioFrameCount(min(remaining, max(chunkFrames, 8_192)))
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else {
        usleep(120_000)
        continue
      }
      file.framePosition = start
      do {
        try file.read(into: buffer)
      } catch {
        // Truncated frame at the tail of a partially written file: wait for more bytes.
        usleep(100_000)
        continue
      }
      guard buffer.frameLength > 0 else {
        usleep(100_000)
        continue
      }

      // Drop the chunk if a seek moved the play head while we were decoding.
      stateLock.lock()
      guard nextFrame == start else {
        stateLock.unlock()
        continue
      }
      nextFrame += AVAudioFramePosition(buffer.frameLength)
      scheduledFrames += AVAudioFramePosition(buffer.frameLength)
      stateLock.unlock()
      playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
    }
  }

  private func bufferedSeconds() -> Double {
    guard streamSampleRate > 0 else { return 0 }
    let played = playerFramesPlayed()
    stateLock.lock()
    let scheduled = scheduledFrames
    stateLock.unlock()
    let pending = max(0, scheduled - played)
    return Double(pending) / streamSampleRate / Double(max(rate, 0.5))
  }

  private func playerFramesPlayed() -> AVAudioFramePosition {
    guard let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
    return AVAudioFramePosition(playerTime.sampleTime)
  }

  // MARK: - position / state

  private func startTicking() {
    stopTicking()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self else { return }
      let played = self.playerFramesPlayed()
      self.stateLock.lock()
      let scheduled = self.scheduledFrames
      let head = self.nextFrame
      self.stateLock.unlock()
      let seconds = Double(head - (scheduled - played)) / self.streamSampleRate
      let clamped = max(0, min(max(self.duration, seconds), seconds))
      DispatchQueue.main.async { self.position = clamped }

      if self.isPlaying, self.bufferedSeconds() < 0.4, !self.fileComplete {
        DispatchQueue.main.async {
          self.isBuffering = true
          self.playerNode.pause()
          self.isPlaying = false
        }
      } else if !self.isPlaying, self.isBuffering, self.bufferedSeconds() > 1.2 {
        DispatchQueue.main.async {
          self.isBuffering = false
          self.ensureEngineRunning()
          self.playerNode.play()
          self.isPlaying = true
        }
      }
      if self.eofReached, self.bufferedSeconds() < 0.05 {
        DispatchQueue.main.async {
          self.isPlaying = false
          self.stopTicking()
        }
      }
      if let downloader = self.download {
        if downloader.isComplete {
          if !self.fileComplete {
            self.fileComplete = true
            DispatchQueue.main.async { self.progress = 1 }
          }
        } else if downloader.expectedBytes > 0 {
          let ratio = min(0.99, Double(downloader.bytesWritten) / Double(downloader.expectedBytes))
          DispatchQueue.main.async { self.progress = ratio }
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stopTicking() {
    timer?.invalidate()
    timer = nil
  }
}

/// Streams a URL to disk, exposing how much has landed so the decoder can follow.
final class ProgressiveDownload: NSObject {
  let url: URL
  let destination: URL

  private let lock = NSLock()
  private var written: Int64 = 0
  private var expected: Int64 = 0
  private var complete = false
  private var handle: FileHandle?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private let delegate: Delegate

  var bytesWritten: Int64 {
    lock.lock(); defer { lock.unlock() }
    return written
  }

  var expectedBytes: Int64 {
    lock.lock(); defer { lock.unlock() }
    return expected
  }

  var isComplete: Bool {
    lock.lock(); defer { lock.unlock() }
    return complete
  }

  init(url: URL, destination: URL) {
    self.url = url
    self.destination = destination
    self.delegate = Delegate()
    super.init()  // NSObject: URLSession delegate callbacks need a class
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    handle = try? FileHandle(forWritingTo: destination)
    delegate.onData = { [weak self] data in
      guard let self else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      try? self.handle?.write(contentsOf: data)
      self.written += Int64(data.count)
    }
    delegate.onResponse = { [weak self] total in
      guard let self, total > 0 else { return }
      self.lock.lock()
      self.expected = total
      self.lock.unlock()
    }
    delegate.onFinish = { [weak self] error in
      guard let self else { return }
      self.lock.lock()
      self.complete = error == nil
      try? self.handle?.close()
      self.handle = nil
      self.lock.unlock()
    }
  }

  func start() {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(with: request)
    self.task = task
    task.resume()
  }

  func cancel() {
    task?.cancel()
    session?.invalidateAndCancel()
    lock.lock()
    try? handle?.close()
    handle = nil
    lock.unlock()
    try? FileManager.default.removeItem(at: destination)
  }

  final class Delegate: NSObject, URLSessionDataDelegate {
    var onData: ((Data) -> Void)?
    var onResponse: ((Int64) -> Void)?
    var onFinish: ((Error?) -> Void)?

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      onResponse?(response.expectedContentLength)
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      onData?(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      onFinish?(error)
    }
  }
}
