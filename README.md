# Cadence · 韵律 — 原生 macOS 音乐播放器

用 SwiftUI + JavaScriptCore + AVAudioEngine 重写 Q-music 的关键路径：
**保留 LX 音源脚本生态，丢掉 Chromium**。

界面上的四个来源用隐喻名，不出现上游品牌：

| 内部 | 显示 | 取意 |
|---|---|---|
| kg | 鲸 | 蓝色 · 曲库深 |
| wy | 焰 | 红色 · 热榜 |
| kw | 珀 | 橙色 · 琥珀 |
| tx | 萤 | 绿色 · 微光 |

### 命名与迁移

内部标识也一并改了，不再有 `QMusicNative` 残留：

| 项 | 旧 | 新 |
|---|---|---|
| 产物 / 可执行文件 | `QMusicNative.app` | `Cadence.app` / `Contents/MacOS/Cadence` |
| Bundle ID | `dev.lxspike.qmusicnative` | `dev.cadence.player` |
| 数据目录 | `Application Support/QMusicNative` | `Application Support/Cadence` |
| 缓存目录 | `Caches/QMusicNative` | `Caches/Cadence` |
| 下载目录 | `~/Music/Q Music/<平台>` | `~/Music/Cadence/<鲸\|焰\|珀\|萤>` |
| UserDefaults 域 | `dev.lxspike.qmusicnative` | `dev.cadence.player` |

`Migration.swift` 在首次启动时做一次性搬家：移动三个目录、复制偏好（含把
`downloadDirectory` 里的旧路径改写）、并把旧的平台名下载文件夹
（酷狗/网易云/酷我/QQ 音乐）改成隐喻名（鲸/焰/珀/萤）。已验证：旧下载的 flac 仍在
`~/Music/Cadence/鲸/`。

```
音源脚本(.js) ──JavaScriptCore──▶ 播放地址
                                      │
酷狗公开接口 ──▶ 搜索 / 歌词          ▼
                              URLSession 下载
                                      │
                    AVAudioEngine: playerNode → 10 段 EQ → 变速变调 → mixer
                                      │
              SwiftUI 界面 + NSPanel 桌面歌词 + MPRemoteCommandCenter 媒体键
```

## 目录

| 路径 | 作用 |
|---|---|
| `Sources/LxSourceKit/` | 音源运行时：`LXEngine`（JSC + `lx` 桥 + crypto/buffer/zlib） |
| `Sources/lxspike/` | 命令行验证器（Phase 0 的产物，`RESULTS.md` 里的数据都来自它） |
| `Sources/Cadence/` | macOS App：音频引擎、搜索、歌词、界面、自检 |
| `Sources/Cadence/Brand.swift` | 产品名与平台隐喻名（改名只改这里） |
| `scripts/` | mock 后端 + 全表面测试音源 |
| `build-app.sh` | 打包成 `Cadence.app`（Info.plist + ad-hoc 签名） |

## 构建与运行

```sh
# 命令行验证器（不需要导入音源，用内置 mock 或真实脚本）
swift build && ./.build/debug/lxspike <source.js> --source kg --verbose

# App
./build-app.sh                       # 生成 .build/Cadence.app
open .build/Cadence.app
```

首次启动是空态：侧栏「音源」→「导入脚本…」选一个 LX 格式的 `.js`。
脚本会复制到 `~/Library/Application Support/Cadence/Sources/`，下次自动加载。

### 无界面自检

```sh
QMUSIC_SOURCE=/path/to/source.js \
  .build/Cadence.app/Contents/MacOS/Cadence --selftest
```

跑通「加载音源 → 搜索 → 取链 → 歌词 → 下载 → 解码 → 播放推进 → 暂停」，
任何一步失败非零退出。

```sh
.build/Cadence.app/Contents/MacOS/Cadence --snapshot /tmp/ui.png
```

把真实 UI 离屏渲染成 PNG（主窗口 + 桌面歌词面板各一张），用于无截屏权限时验收界面。

## 已实现

- 音源脚本在 `JSContext` 里运行，`lx.request / crypto / buffer / zlib / timers` 与 Q-music 的 preload 对齐
- **四平台搜索**：酷狗 / 网易云 / 酷我 / QQ 音乐，各自适配接口与 `musicInfo` 字段
  （`toOldMusicInfo` 兼容：`hash` / `songmid` / `rid` / `strMediaMid` / `copyrightId` …）
- **歌词**：酷狗（krcs→lyrics，base64 LRC）、网易云、QQ 音乐；支持翻译轨合并；
  **跨源回退**：任何源拿不到歌词时，用「歌名 + 歌手」在焰（网易云）匹配一次，所以珀（酷我）也有歌词
- **渐进流播放**：下载 0.6–0.7 秒后出声（不等整首），边下边解码，缓冲不足自动暂停续播；
  保留 10 段 EQ 预设、0.5–2.0x 变速（`AVAudioFile` 分块读取 → PCM → `AVAudioPlayerNode`）
- **下载**：队列式、逐项进度、按平台分目录、重名自动加序号、Finder 定位、可取消
- 桌面歌词：无边框 `NSPanel`，非激活、全空间常驻、当前行高亮 + 上下文淡出
- 媒体键与系统「正在播放」：`MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`，
  进度随播放同步刷新，控制中心可拖拽定位
- 音源管理：本地导入脚本 / **从链接导入（内联输入行，不是弹窗）** / 删除 / 切换，重名不会互相覆盖
- macOS 形态：`NavigationSplitView` 侧栏 + 统一工具栏 `.searchable` 搜索 + `Settings` 面板 + ⌘D 下载
- **菜单栏常驻**：关窗口不退出，缩到菜单栏；菜单里可播放/暂停、上一首/下一首、显示主窗口、桌面歌词、设置、退出
  （关窗是「隐藏」而非销毁，SwiftUI 的窗口 delegate 通过转发代理保留）
- 界面细节：真实封面（内存 + 磁盘双层缓存、限流预取）、播放中均衡器动效、带缓冲区的自绘进度条、
  骨架屏、空状态、失败重试、播放键悬停反馈
- **自绘 App 图标**：与界面里"播放中"的三根均衡器条同源，Dock 与菜单栏（播放中 `waveform`）一致

## 实测平台覆盖（2026-11-20，来源 www.imwzh.com/lxmusic/）

| 平台 | 搜索 | 取链 | 歌词 | 备注 |
|---|---|---|---|---|
| 酷狗 kg | ✅ | ✅ | ✅ | |
| 网易云 wy | ✅ | ✅ | ✅ | |
| 酷我 kw | ✅ | ✅ | — | 无公开歌词接口 |
| QQ tx | ✅ | ✅ | ✅ | 搜索走 smartbox，结果条数受限 |
| 咪咕 mg | ❌ | — | — | 搜索接口需签名/JS 校验，未接 |

具体到音源：`fish_music v1.9.0` 四平台中 kg/kw/tx 全链路通过（kg 出 34.5 MB FLAC），
wy 被它自己的“跨源严格匹配”拒绝；`HYWmusic` 后端返回 HTML，四平台全挂。

## 未实现（别当成已完成）
- **先下载后播放**。渐进流 + EQ 需要 `AudioFileStream`/`MTAudioProcessingTap`，现在整首下完才出声
- **咪咕（mg）** 搜索接口没有可用匿名入口
- 无曲库/歌单/播放历史持久化（没有 SQLite），无账号登录、无云同步
- 桌面歌词只解析 LRC；KRC 逐字歌词未做
- 未做沙盒、Developer ID 签名、公证、自动更新
- 媒体键、NSPanel 的跨空间行为、深色/浅色切换只在离屏渲染下检查过，**没有真机交互验收**

## 渐进流实测（52.8 MB FLAC，`fish_music` 音源）

```
stream   started in 0.69 s  (est. duration 270 s, downloaded 1%)
playing  position 2.98 s  buffered through 20.0 s  downloaded 100%
seek     → 15.0 s, now 16.0 s  (ok)
```

## 量到的数字（arm64 macOS 27.2.1）

| 场景 | RSS |
|---|---|
| 音源运行时（`lxspike`，单进程） | 19–25 MB |
| Cadence 空转，未加载音源 | ~143 MB（SwiftUI/AppKit/AVFoundation/MediaPlayer 基线） |
| Cadence 加载 1 个 640 KB 音源脚本 | ~150 MB，脚本跑定时器后会缓慢增长 |
| 播放中（无窗口，自检） | 78–81 MB |
| 封面缓存上限 | 48 张 / ≤256 px，约 10 MB |

内存策略：每个音源独立 `JSVirtualMachine`；同一时刻只保留**当前音源**的引擎；
闲置 90 s（菜单栏模式 30 s）后释放引擎与音频引擎。
注意：释放后 JS 堆会还给分配器，但 macOS 不把这些页还给系统，所以
RSS 表现为**停止增长/平台化**而不是明显下降；真正收益是脚本定时器停下、后续不会再爬。

App 壳的基线来自 SwiftUI/AppKit/AVFoundation/MediaPlayer 框架本身，不是音源运行时；
音源部分每个约 20 MB，与 CLI 实测一致。

## 优化记录

- 搜索：450 ms 防抖 + 任务取消 + 结果归属校验（旧请求不会覆盖新结果）
- 音源加载：`withTaskGroup` 并行，不再串行等每个握手
- 下载：并发上限 3，其余排队；取消/重试/清空
- 封面：请求只发生在播放条与下载行（列表行仅在搜索结果自带封面时才拉）
- 偏好持久化：平台、音质、侧栏分组、音量、EQ、窗口位置、桌面歌词位置
- seek 全曲可用：超出缓冲区间时读循环等待下载追上，并显示缓冲状态（实测拖到 80% 正常续播）
- 重复点击下载不会排队两次（同曲同音质去重）
- `⌘1 / ⌘2 / ⌘3` 切搜索 / 下载 / 音源
- 封面缓存可清：设置里显示张数与占用，一键清除（内存 + 磁盘）

## 已知捕获限制

离屏渲染时窗口的 **toolbar 安全区会被画成浅色**，压住搜索页顶部那一行（分段控件与按钮），
看起来像“空白胶囊”。控件本身在 `-probe.png` 探针里渲染完全正常，说明是捕获路径而非布局问题。
图标、列表、徽标、播放条、歌词面板都正常。真窗口仍需人工看一眼。

`--snapshot` 会输出 5 张图：主窗口、音源页、下载页、歌词面板、控件探针。

## 说明与免责

- 本项目是**独立实现**：不使用、也不包含任何上游项目的代码，也不附带任何音源脚本。
  音源需要你自己导入（LX 格式的 `.js`），脚本由第三方提供，本仓库不分发。
- 通过脚本解析出的播放地址指向第三方服务，请遵守你所在地区的法律与各平台的服务条款。
- 界面里的四个来源使用隐喻名（鲸/焰/珀/萤），不涉及上游商标。
- 许可：MIT（见 [LICENSE](./LICENSE)）。
