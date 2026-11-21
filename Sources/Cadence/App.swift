import AppKit
import SwiftUI

@main
struct CadenceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var state = AppState()

  init() {
    AppDelegate.launchedAt = Date()
    SelfTest.runIfRequested()
    if let snapshot = SelfTest.snapshotPath {
      // Give NSApplication a beat to finish launching before rendering offscreen.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        Task { @MainActor in await SelfTest.renderSnapshot(to: snapshot) }
      }
    }
  }

  var body: some Scene {
    Window(Brand.name, id: WindowBridge.mainSceneID) {
      ContentView()
        .environmentObject(state)
        .environmentObject(state.audio)
        .frame(minWidth: 980, minHeight: 620)
    }
    .defaultSize(width: 1160, height: 760)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .saveItem) {
        Button("下载选中歌曲") { state.downloadSelected() }
          .keyboardShortcut("d", modifiers: [.command])
          .disabled(state.selection == nil)
      }
      CommandGroup(after: .sidebar) {
        Button("显示主窗口") { WindowBridge.shared.show() }
          .keyboardShortcut("0", modifiers: [.command])
      }
      CommandGroup(after: .toolbar) {
        Button("搜索") { state.section = .search }
          .keyboardShortcut("1", modifiers: [.command])
        Button("下载") { state.section = .downloads }
          .keyboardShortcut("2", modifiers: [.command])
        Button("音源") { state.section = .sources }
          .keyboardShortcut("3", modifiers: [.command])
      }
      CommandMenu("播放") {
        Button("播放 / 暂停") { state.audio.toggle() }
          .keyboardShortcut(.space, modifiers: [])
          .disabled(state.currentSong == nil)
        Button("上一首") { state.step(-1) }
        Button("下一首") { state.step(1) }
        Divider()
        Button(state.showLyricPanel ? "隐藏桌面歌词" : "显示桌面歌词") {
          state.showLyricPanel.toggle()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
      }
    }

    // Closing the window folds the app into the menu bar instead of quitting.
    MenuBarExtra {
      MenuBarPanel()
        .environmentObject(state)
        .environmentObject(state.audio)
    } label: {
      Image(systemName: state.audio.isPlaying ? "waveform" : "music.note.list")
        .accessibilityLabel(Brand.name)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView()
        .environmentObject(state)
        .environmentObject(state.audio)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var observer: NSObjectProtocol?
  static var launchedAt = Date()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
      // Time to first frame, for perf tracking in the log.
      NSLog("启动完成 %.0f ms", Date().timeIntervalSince(Self.launchedAt) * 1000)
    }

    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard let window = notification.object as? NSWindow,
            !(window is NSPanel),
            !window.className.contains("Settings") else { return }
      WindowBridge.shared.adopt(window: window)
    }
  }

  /// The app lives in the menu bar: closing the window must not quit it.
  /// SwiftUI reopens the window through `openWindow(id:)`.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

/// Keeps the main window alive when the user closes it, and brings it back from
/// the menu bar. Closing is intercepted (hide, not close) because SwiftUI will not
/// reliably recreate a window that was really closed.
///
/// The delegate forwards everything it does not own back to SwiftUI's own window
/// delegate — replacing that delegate outright breaks window bookkeeping.
@MainActor
final class WindowBridge: NSObject, NSWindowDelegate {
  static let shared = WindowBridge()
  static let mainSceneID = "main"

  private weak var window: NSWindow?
  private weak var upstream: NSWindowDelegate?

  func adopt(window: NSWindow) {
    guard self.window !== window else { return }
    self.window = window
    if window.delegate !== self {
      upstream = window.delegate
      window.delegate = self
      window.isReleasedWhenClosed = false
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    NotificationCenter.default.post(name: .cadenceWindowHidden, object: nil)
    return false
  }

  override func responds(to selector: Selector!) -> Bool {
    if super.responds(to: selector) { return true }
    return upstream?.responds(to: selector) ?? false
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if upstream?.responds(to: selector) == true { return upstream }
    return super.forwardingTarget(for: selector)
  }

  func show() {
    surface()
    // A status-menu click can swallow the activation while its tracking loop is
    // still unwinding; repeat once the loop is done.
    DispatchQueue.main.async { [weak self] in self?.surface() }
  }

  private func surface() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window = self.window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.orderFrontRegardless()
    window.makeKeyAndOrderFront(nil)
  }
}

extension Notification.Name {
  static let cadenceWindowHidden = Notification.Name("cadence.window.hidden")
}

/// Menu bar dropdown: transport, window, lyrics, quit.
struct MenuBarPanel: View {
  @EnvironmentObject var state: AppState
  @EnvironmentObject var audio: AudioEngine

  var body: some View {
    if let song = state.currentSong {
      Text("\(song.name) — \(song.singer)")
      Text(audio.isPlaying ? "正在播放" : "已暂停")
      Divider()
    }

    Button(audio.isPlaying ? "暂停" : "播放") { audio.toggle() }
      .keyboardShortcut(.space, modifiers: [])
      .disabled(state.currentSong == nil)
    Button("上一首") { state.step(-1) }
      .disabled(state.songs.isEmpty)
    Button("下一首") { state.step(1) }
      .disabled(state.songs.isEmpty)

    Divider()

    Button("显示主窗口") { WindowBridge.shared.show() }
    Toggle("桌面歌词", isOn: $state.showLyricPanel)
    Button("设置…") {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    Divider()
    Button("退出 \(Brand.name)") { NSApp.terminate(nil) }
      .keyboardShortcut("q", modifiers: [.command])
  }
}
