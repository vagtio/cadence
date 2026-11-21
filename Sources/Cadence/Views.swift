import SwiftUI

extension Platform {
  var tint: Color {
    switch self {
    case .kg: return Color(red: 0.16, green: 0.60, blue: 0.98)
    case .wy: return Color(red: 0.90, green: 0.16, blue: 0.20)
    case .kw: return Color(red: 0.98, green: 0.55, blue: 0.12)
    case .tx: return Color(red: 0.18, green: 0.74, blue: 0.46)
    }
  }
}

struct PlatformBadge: View {
  let platform: Platform
  var compact = false

  var body: some View {
    Text(platform.displayName)
      .font(.system(size: compact ? 9 : 10, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: compact ? 22 : 24, height: compact ? 14 : 16)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(platform.tint.opacity(0.9))
      )
      .help(platform.subtitle)
  }
}

struct PlatformPicker: View {
  let platforms: [Platform]
  @Binding var selection: Platform

  var body: some View {
    HStack(spacing: 2) {
      ForEach(platforms) { platform in
        Button {
          selection = platform
        } label: {
          HStack(spacing: 5) {
            Circle()
              .fill(platform.tint)
              .frame(width: 6, height: 6)
            Text(platform.displayName)
              .font(.system(size: 12, weight: selection == platform ? .semibold : .regular))
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(selection == platform ? Color.primary.opacity(0.13) : Color.clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.06))
    )
    .fixedSize()
  }
}

// MARK: - shell

struct ContentView: View {
  @EnvironmentObject var state: AppState
  /// Snapshot builds skip the toolbar search field, whose reserved safe area
  /// renders as an empty band when the window toolbar is not part of the capture.
  var isSnapshot = false

  var body: some View {
    VStack(spacing: 0) {
      NavigationSplitView {
        sidebar
          .navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 260)
      } detail: {
        if isSnapshot {
          // No toolbar at all: SwiftUI would reserve its strip and the offscreen
          // capture shows that strip as an empty band.
          detail
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        } else {
          detail
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .searchable(text: $state.keyword, prompt: "搜索歌曲、歌手")
            .onSubmit(of: .search) { state.search() }
            .toolbar { toolbar }
        }
      }
      Divider()
      PlayerBar()
    }
    .background(WindowAccessor())
    .task { await state.loadSourcesFromDisk() }
  }

  private var sidebar: some View {
    List {
      Section("发现") {
        sidebarRow(.search, title: "搜索", symbol: "magnifyingglass")
        sidebarRow(.downloads, title: "下载", symbol: "arrow.down.circle", badge: state.downloads.activeCount)
      }
      Section("来源") {
        sidebarRow(.sources, title: "音源", symbol: "puzzlepiece.extension")
      }
    }
    .listStyle(.sidebar)
    // The footer must not be scrolled over by the list.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        sidebarFooter
      }
    }
  }

  /// Rows carry their own tap handling: `List(selection:)` on macOS drops clicks
  /// that any row gesture touches, which is what made 下载 feel dead.
  private func sidebarRow(
    _ section: AppState.Section,
    title: String,
    symbol: String,
    badge: Int = 0
  ) -> some View {
    let isSelected = state.section == section
    return HStack(spacing: 8) {
      Label(title, systemImage: symbol)
        .labelStyle(.titleAndIcon)
      Spacer(minLength: 0)
      if badge > 0 {
        Text("\(badge)")
          .font(.system(size: 10, weight: .semibold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.accentColor.opacity(0.9)))
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    )
    .onTapGesture { state.section = section }
  }

  private var sidebarFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: "waveform.badge.mic")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(state.activeSource?.info.name ?? "未加载音源")
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
        HStack(spacing: 3) {
          ForEach(state.supportedPlatforms) { platform in
            PlatformBadge(platform: platform, compact: true)
          }
        }
        .padding(.top, 1)
      }
      Spacer(minLength: 0)
      Button {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .help("设置（⌘,）")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var title: String {
    switch state.section {
    case .downloads: return "下载"
    case .sources: return "音源"
    default: return "搜索"
    }
  }

  private var subtitle: String {
    switch state.section {
    case .downloads:
      return "\(state.downloads.items.count) 个任务"
    case .sources:
      return "\(state.loadedSources.count) 个音源"
    default:
      guard state.currentSong != nil else { return "" }
      return state.audio.isPlaying ? "正在播放" : "已暂停"
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch state.section {
    case .downloads: DownloadsPane()
    case .sources: SourcesPane()
    default: SearchPane()
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Picker("音质", selection: $state.quality) {
          ForEach(state.availableQualities(for: state.platform), id: \.self) { quality in
            Text(quality).tag(quality)
          }
        }
      } label: {
        Label(state.quality, systemImage: "waveform")
      }
      .help("播放与下载音质")
      .disabled(state.availableQualities(for: state.platform).isEmpty)
    }
    ToolbarItem(placement: .primaryAction) {
      Menu {
        let qualities = downloadQualities
        if let name = state.selectedSong?.name {
          Section("下载「\(name)」") {
            ForEach(qualities, id: \.self) { quality in
              Button("下载 \(quality)") { state.downloadSelected(quality: quality) }
            }
          }
        } else {
          Text("先在列表里点一首歌")
          Text("单击选中，双击播放")
        }
      } label: {
        Label("下载", systemImage: "arrow.down.to.line")
      }
      .help("选中歌曲后可按音质下载")
    }
  }

  private var downloadQualities: [String] {
    guard let song = state.selectedSong else { return [] }
    return state.availableQualities(for: song.platform)
  }
}

// MARK: - search

final class SearchUIState: ObservableObject {
  @Published var hovered: Song.ID?
}

struct SearchPane: View {
  @EnvironmentObject var state: AppState
  @StateObject private var ui = SearchUIState()

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      statusBar
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      if state.supportedPlatforms.isEmpty {
        Text("音源未声明可用平台")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      } else {
        PlatformPicker(platforms: state.supportedPlatforms, selection: $state.platform)
      }
      Spacer(minLength: 8)
      if !state.songs.isEmpty && !state.isSearching {
        Text("\(state.songs.count) 首")
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
  }

  @ViewBuilder
  private var content: some View {
    if state.loadedSources.isEmpty {
      onboarding
    } else if state.isSearching && state.songs.isEmpty {
      skeleton
    } else if state.songs.isEmpty {
      placeholder
    } else {
      list
    }
  }

  private var list: some View {
    List {
      ForEach(state.songs) { song in
        SongRow(
          song: song,
          isCurrent: state.currentSong?.id == song.id,
          isSelected: state.selection == song.id,
          isPlaying: state.audio.isPlaying,
          isHovered: ui.hovered == song.id,
          qualities: state.availableQualities(for: song.platform),
          onPlay: { state.play(song) },
          onDownload: { quality in state.download(song, quality: quality) }
        )
        .contentShape(Rectangle())
        .onHover { inside in
          if inside { ui.hovered = song.id } else if ui.hovered == song.id { ui.hovered = nil }
        }
        // A plain tap selects, a double tap plays. `exclusively` keeps the List's
        // own row tracking from eating the single click.
        .gesture(
          TapGesture(count: 2).onEnded { state.play(song) }
            .exclusively(before: TapGesture(count: 1).onEnded { state.selection = song.id })
        )
        .contextMenu {
          Button("播放") { state.play(song) }
          Menu("下载") {
            ForEach(state.availableQualities(for: song.platform), id: \.self) { quality in
              Button("下载 \(quality)") { state.download(song, quality: quality) }
            }
          }
        }
      }
    }
    .listStyle(.inset)
  }

  private var skeleton: some View {
    VStack(spacing: 0) {
      ForEach(0..<6, id: \.self) { index in
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 36, height: 36)
          VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 180, height: 9)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(width: 110, height: 8)
          }
          Spacer()
          RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(width: 34, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .opacity(1 - Double(index) * 0.12)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 6)
  }

  private var onboarding: some View {
    EmptyState(
      symbol: "puzzlepiece.extension",
      tint: .accentColor,
      title: "先导入一个音源脚本",
      message: "LX 格式的 .js 音源脚本，导入后即可在酷狗、网易云、酷我、QQ 音乐之间搜索并播放。",
      action: ("导入音源…", { state.importSource() })
    )
  }

  private var placeholder: some View {
    EmptyState(
      symbol: "magnifyingglass",
      tint: Color.secondary,
      title: state.keyword.isEmpty ? "搜索歌曲或歌手" : "没有找到「\(state.keyword)」",
      message: state.keyword.isEmpty
        ? "在工具栏搜索框输入关键词，回车开始搜索。"
        : "换个关键词，或切换到其他平台再试一次。",
      action: nil
    )
  }

  private var statusBar: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(state.audio.isPlaying ? Color.green : Color.secondary.opacity(0.35))
        .frame(width: 6, height: 6)
      Text(state.audio.isBuffering && !state.audio.isLoading ? "缓冲中…" : state.message)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let song = state.currentSong {
        Text("\(song.platform.displayName) · \(state.quality)")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(.regularMaterial)
  }
}

struct EmptyState: View {
  let symbol: String
  let tint: Color
  let title: String
  let message: String
  let action: (label: String, run: () -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      // ZStack rather than .background(): layered backgrounds lose their opacity
      // and drop the glyph when the view is drawn into an offscreen layer.
      ZStack {
        Circle()
          .fill(tint.opacity(0.14))
          .frame(width: 54, height: 54)
        Image(systemName: symbol)
          .font(.system(size: 21, weight: .regular))
          .foregroundStyle(tint)
      }
      .frame(width: 54, height: 54)
      VStack(spacing: 4) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
        Text(message)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
      }
      if let action {
        Button(action.label, action: action.run)
          .controlSize(.small)
          .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

struct SongRow: View {
  let song: Song
  let isCurrent: Bool
  let isSelected: Bool
  let isPlaying: Bool
  let isHovered: Bool
  let qualities: [String]
  let onPlay: () -> Void
  let onDownload: (String) -> Void

  var body: some View {
    HStack(spacing: 10) {
      ArtworkView(song: song, size: 36, corner: 6, autoLoad: true)

      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          Text(song.name)
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .lineLimit(1)
          if isCurrent {
            if isPlaying {
              EQBars(playing: true)
            } else {
              Image(systemName: "waveform")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
          }
        }
        HStack(spacing: 6) {
          Text(song.singer)
            .lineLimit(1)
          if !song.album.isEmpty {
            Text("·")
              .foregroundStyle(.quaternary)
            Text(song.album)
              .lineLimit(1)
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      }
      .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

      Text(song.durationText)
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)

      HStack(spacing: 4) {
        Button(action: onPlay) {
          Image(systemName: "play.fill")
            .font(.system(size: 10))
        }
        .help("播放")
        Menu {
          ForEach(qualities, id: \.self) { quality in
            Button("下载 \(quality)") { onDownload(quality) }
          }
        } label: {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .help("按音质下载")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .frame(width: 44, alignment: .trailing)
      .opacity(isHovered || isCurrent ? 1 : 0)
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 2)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(
          isSelected ? Color.accentColor.opacity(0.16)
            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
    )
  }
}

// MARK: - downloads

struct DownloadsPane: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(state.downloads.directory.path)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Button("打开文件夹") { state.downloads.openDirectory() }
          .controlSize(.small)
        Button("清空已完成") { state.downloads.clearFinished() }
          .controlSize(.small)
          .disabled(!state.downloads.items.contains { $0.state == .done })
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      Divider()

      if state.downloads.items.isEmpty {
        EmptyState(
          symbol: "arrow.down.circle",
          tint: .accentColor,
          title: "还没有下载任务",
          message: "在搜索结果里点行尾的 ↓ 选择音质，或按 ⌘D 用当前音质下载。MP3 会把封面和歌词写进文件本身。",
          action: nil
        )
      } else {
        List {
          ForEach(state.downloads.items) { item in
            DownloadRow(item: item)
          }
        }
        .listStyle(.inset)
      }
    }
  }
}

struct DownloadRow: View {
  @EnvironmentObject var state: AppState
  let item: DownloadManager.Item

  var body: some View {
    HStack(spacing: 10) {
      ArtworkView(song: item.song, size: 30, corner: 5, autoLoad: true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.song.name)
            .font(.system(size: 13))
            .lineLimit(1)
          PlatformBadge(platform: item.song.platform, compact: true)
          Text(item.quality)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
        }
        if item.state == .downloading {
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Capsule().fill(Color.primary.opacity(0.10))
              Capsule()
                .fill(Color.accentColor)
                .frame(width: max(2, geometry.size.width * item.progress))
            }
          }
          .frame(height: 3)
          .padding(.trailing, 60)
        }
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(isFailed ? Color.red.opacity(0.9) : .secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      switch item.state {
      case .done:
        Button("显示") { state.downloads.reveal(item) }
          .controlSize(.small)
      case .downloading, .queued:
        Button("取消") { state.downloads.cancel(item) }
          .controlSize(.small)
      case .failed:
        Button("重试") { state.download(item.song, quality: item.quality) }
          .controlSize(.small)
        Button("移除") { state.downloads.remove(item) }
          .controlSize(.small)
      }
      Button {
        state.downloads.remove(item)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.tertiary)
      .help("从列表移除")
    }
    .padding(.vertical, 5)
  }

  private var isFailed: Bool {
    if case .failed = item.state { return true }
    return false
  }

  private var detail: String {
    switch item.state {
    case .queued: return "排队中"
    case .downloading:
      return String(format: "%.1f MB · %d%%", Double(item.bytes) / 1_048_576, Int(item.progress * 100))
    case .done:
      let name = item.fileURL?.lastPathComponent ?? "已完成"
      return item.extras.map { "\(name) · \($0)" } ?? name
    case .failed(let message): return message
    }
  }
}

// MARK: - sources

struct SourcesPane: View {
  @EnvironmentObject var state: AppState

  private func submitImport() {
    let url = state.importURL
    state.importURL = ""
    state.showingImportField = false
    Task { await state.importSource(fromRemote: url) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        if state.isImporting {
          ProgressView().controlSize(.mini)
          Text("正在初始化音源…")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          Text("已加载 \(state.loadedSources.count) 个")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("打开目录") { NSWorkspace.shared.open(state.sourceDirectory) }
          .controlSize(.small)
        Button("从链接导入…") { state.showingImportField.toggle() }
          .controlSize(.small)
        Button("导入脚本…") { state.importSource() }
          .controlSize(.small)
      }

      if state.showingImportField {
        HStack(spacing: 8) {
          Image(systemName: "link")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
          TextField("粘贴音源脚本直链（.js）", text: $state.importURL)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 460)
            .onSubmit { submitImport() }
          Button("导入") { submitImport() }
            .disabled(state.importURL.trimmingCharacters(in: .whitespaces).isEmpty)
          Button("取消") {
            state.importURL = ""
            state.showingImportField = false
          }
          .buttonStyle(.borderless)
          Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
      }

      if state.loadedSources.isEmpty {
        EmptyState(
          symbol: "puzzlepiece.extension",
          tint: .accentColor,
          title: "还没有音源",
          message: "导入 LX 格式的 .js 脚本。它在独立的 JavaScriptCore 上下文里运行，不使用 WebView。",
          action: ("导入脚本…", { state.importSource() })
        )
      } else {
        List {
          ForEach(state.loadedSources) { source in
            SourceRow(source: source, isActive: state.activeSource?.id == source.id) {
              state.activeSourceID = source.id
            } onRemove: {
              state.remove(source)
            }
          }
        }
        .listStyle(.inset)
      }

      Text(state.sourceDirectory.path)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
    .padding(16)
  }
}

struct SourceRow: View {
  let source: AppState.LoadedSource
  let isActive: Bool
  let onActivate: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 13))
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
      VStack(alignment: .leading, spacing: 3) {
        Text(source.info.name.isEmpty ? source.id : source.info.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Text("v\(source.info.version) · \(source.info.author)")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack(spacing: 3) {
          ForEach(Platform.allCases.filter { source.engines[$0.rawValue] != nil }) { platform in
            PlatformBadge(platform: platform, compact: true)
          }
        }
      }
      Spacer(minLength: 8)
      Button("设为当前") { onActivate() }
        .controlSize(.mini)
        .disabled(isActive)
      Button(role: .destructive, action: onRemove) {
        Image(systemName: "trash")
          .font(.system(size: 10))
      }
      .controlSize(.mini)
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 5)
    .onTapGesture(count: 2) { onActivate() }
  }
}

// MARK: - player bar

final class PlayerUIState: ObservableObject {
  @Published var hoveringPlay = false
}

struct PlayerBar: View {
  @EnvironmentObject var state: AppState
  @EnvironmentObject var audio: AudioEngine
  @StateObject private var ui = PlayerUIState()

  var body: some View {
    HStack(spacing: 14) {
      ArtworkView(song: state.currentSong, size: 50, corner: 8, autoLoad: true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(state.currentSong?.name ?? "未在播放")
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          if let song = state.currentSong {
            PlatformBadge(platform: song.platform, compact: true)
          }
        }
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 216, alignment: .leading)

      HStack(spacing: 10) {
        Button { state.step(-1) } label: {
          Image(systemName: "backward.fill").font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .disabled(state.songs.isEmpty)

        Button { audio.toggle() } label: {
          if audio.isLoading {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 13, weight: .semibold))
              .frame(width: 30, height: 30)
              .background(Circle().fill(Color.primary.opacity(ui.hoveringPlay ? 0.16 : 0.10)))
              .contentShape(Circle())
              .scaleEffect(ui.hoveringPlay ? 1.04 : 1)
          }
        }
        .buttonStyle(.plain)
        .onHover { inside in
          withAnimation(.easeOut(duration: 0.15)) { ui.hoveringPlay = inside }
        }
        .help(audio.isPlaying ? "暂停（空格）" : "播放（空格）")

        Button { state.step(1) } label: {
          Image(systemName: "forward.fill").font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .disabled(state.songs.isEmpty)

        if audio.isBuffering && !audio.isLoading {
          ProgressView().controlSize(.mini).scaleEffect(0.7).help("缓冲中")
        }
      }

      Text(timeText(audio.position))
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 40, alignment: .trailing)

      SeekBar(
        position: audio.position,
        duration: max(audio.duration, 0.01),
        buffered: audio.bufferedThrough,
        onSeek: { audio.seek(to: $0) }
      )
      .frame(minWidth: 140)

      Text(timeText(audio.duration))
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 40, alignment: .leading)

      HStack(spacing: 6) {
        Image(systemName: audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Slider(value: $audio.volume, in: 0...1)
          .controlSize(.mini)
          .frame(width: 66)
      }

      Menu {
        Picker("均衡器", selection: $audio.preset) {
          ForEach(AudioEngine.EQPreset.allCases) { Text($0.rawValue).tag($0) }
        }
        Divider()
        Text("播放速度 \(String(format: "%.2fx", audio.rate))")
        Slider(value: $audio.rate, in: 0.5...2.0)
          .frame(width: 160)
      } label: {
        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
      }
      .menuStyle(.borderlessButton)
      .frame(width: 26)

      Button {
        if let song = state.currentSong { state.download(song) }
      } label: {
        Image(systemName: "arrow.down.circle").font(.system(size: 12))
      }
      .buttonStyle(.borderless)
      .disabled(state.currentSong == nil)
      .help("下载当前歌曲")

      Toggle(isOn: $state.showLyricPanel) {
        Image(systemName: "text.bubble").font(.system(size: 11))
      }
      .toggleStyle(.button)
      .controlSize(.small)
      .help("桌面歌词（⌘⇧L）")
    }
    .padding(.horizontal, 14)
    .frame(height: 64)
    .background(.bar)
  }

  private var subtitle: String {
    guard let song = state.currentSong else {
      return state.message
    }
    let base = song.album.isEmpty ? song.singer : "\(song.singer) · \(song.album)"
    if audio.isBuffering && !audio.isLoading { return "缓冲中…" }
    return base
  }

  private func timeText(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

// MARK: - settings

struct SettingsView: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    Form {
      Section("下载") {
        LabeledContent("目录") {
          HStack(spacing: 8) {
            Text(state.downloads.directory.path)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Button("选择…") { chooseDirectory() }
              .controlSize(.small)
          }
        }
        LabeledContent("标签") {
          Toggle("写入封面与歌词", isOn: $state.embedTags)
            .toggleStyle(.checkbox)
        }
        LabeledContent("音质") {
          Picker("", selection: $state.quality) {
            ForEach(state.availableQualities(for: state.platform), id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden()
          .frame(width: 110)
        }
      }
      Section("音源") {
        LabeledContent("目录") {
          Text(state.sourceDirectory.path)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        LabeledContent("已加载") {
          Text("\(state.loadedSources.count) 个 · \(state.supportedPlatforms.map(\.displayName).joined(separator: " / "))")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
      }
      Section("缓存") {
        LabeledContent("封面缓存") {
          HStack(spacing: 8) {
            Text(ArtworkCache.describe())
              .font(.system(size: 11).monospacedDigit())
              .foregroundStyle(.secondary)
            Button("清除") { ArtworkCache.clear() }
              .controlSize(.small)
          }
        }
      }
      Section("关于") {
        LabeledContent("版本") {
          Text("\(Brand.name) \(Brand.version) · SwiftUI + JavaScriptCore")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 470, height: 400)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    state.downloads.directory = url
  }
}


/// Hands the real NSWindow to `WindowBridge` so the menu bar can focus it again.
struct WindowAccessor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      WindowBridge.shared.adopt(window: window)
      window.setFrameAutosaveName("CadenceMainWindow")
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let window = nsView.window { WindowBridge.shared.adopt(window: window) }
  }
}
