import AppKit
import SwiftUI

/// Floating, non-activating lyrics panel — the native stand-in for Q-music's
/// second BrowserWindow (`src/renderer-lyric`).
final class LyricPanelController {
  private var panel: NSPanel?
  private var moveObserver: NSObjectProtocol?
  private static let frameKey = "lyricPanelFrame"

  func setVisible(_ visible: Bool, state: AppState) {
    if visible {
      show(state: state)
    } else {
      panel?.orderOut(nil)
    }
  }

  private func show(state: AppState) {
    if let panel {
      panel.orderFrontRegardless()
      return
    }
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(760, screen.width - 80), height: 190)
    let frame = Self.restoredFrame(size: size, screen: screen)

    let panel = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.contentView = NSHostingView(rootView: LyricPanelView().environmentObject(state))
    panel.orderFrontRegardless()
    self.panel = panel

    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: .main
    ) { [weak panel] _ in
      guard let panel else { return }
      UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }
  }

  private static func restoredFrame(size: NSSize, screen: NSRect) -> NSRect {
    if let stored = UserDefaults.standard.string(forKey: frameKey) {
      var frame = NSRectFromString(stored)
      if frame.width > 0, frame.height > 0 {
        frame.size = size
        // Keep it on screen even if the display arrangement changed.
        if !screen.intersects(frame) {
          frame.origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40)
        }
        return frame
      }
    }
    return NSRect(
      x: screen.midX - size.width / 2,
      y: screen.minY + 40,
      width: size.width,
      height: size.height
    )
  }
}

struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .hudWindow
  var blending: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blending
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blending
  }
}

struct LyricPanelView: View {
  @EnvironmentObject var state: AppState

  private var lines: [LyricLine] { state.lyrics }
  private var index: Int { state.lyricIndex ?? 0 }

  var body: some View {
    VStack(spacing: 6) {
      if lines.isEmpty {
        VStack(spacing: 4) {
          Text(state.currentSong?.name ?? "未在播放")
            .font(.system(size: 17, weight: .semibold))
          Text(state.currentSong == nil ? "在窗口里选一首歌" : "这首歌没有歌词")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(visibleRange, id: \.self) { offset in
          let position = index + offset
          let line = lines[position]
          Text(line.text)
            .font(.system(
              size: offset == 0 ? 23 : (abs(offset) == 1 ? 16 : 14),
              weight: offset == 0 ? .semibold : .regular
            ))
            .foregroundStyle(offset == 0 ? Color.primary : Color.secondary.opacity(abs(offset) == 1 ? 0.72 : 0.40))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .blur(radius: abs(offset) >= 2 ? 0.8 : 0)
            .scaleEffect(offset == 0 ? 1 : 0.98, anchor: .center)
            .shadow(color: offset == 0 ? Color.black.opacity(0.35) : .clear, radius: 6, x: 0, y: 1)
            .animation(.easeInOut(duration: 0.22), value: index)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 24)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.clear)
        .background(VisualEffectView(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
    )
  }

  private var visibleRange: [Int] {
    guard !lines.isEmpty else { return [] }
    let lower = max(0, index - 1)
    let upper = min(lines.count - 1, index + 3)
    return Array(lower...upper).map { $0 - index }
  }
}
