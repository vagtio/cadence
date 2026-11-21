# Phase 0 结果：音源能否脱离 Chromium 跑在 JavaScriptCore 里

**结论：能。** 未修改的社区音源脚本，在纯 Swift + `JavaScriptCore.framework` 进程里跑通
`inited → musicUrl`，解析出真实可播放地址，进程常驻内存 19–24 MB。

环境：macOS 27.2.1 / arm64，Swift 6.4.2（macOS 13 部署目标），脚本来自
`github.com/pdone/lx-music-source`（50 个 `.js`，20 个独立音源）。

## 一、做了什么

`Sources/lxspike/` 是一个 SwiftPM 可执行程序，替 Q-music 里那两个 Electron 机制：
`src/main/modules/userApi/main.ts`（每个音源一个隐藏 BrowserWindow）
和 `src/main/modules/userApi/renderer/preload.js`（`lx` 桥）。

| 组件 | 对应原实现 | 实现方式 |
|---|---|---|
| JS 运行时 | Chromium renderer | `JSContext`（系统自带 JSC） |
| `lx.request` | `needle` | `URLSession` + 回调进 JS |
| `lx.utils.crypto` | Node `crypto` | CryptoKit / CommonCrypto / Security |
| `lx.utils.buffer` | Node `Buffer` | `Uint8Array` 子类 + `toString('hex'\|'base64'\|'utf8'\|'latin1')` |
| `lx.utils.zlib` | Node `zlib` | C shim → `libz` |
| `setTimeout`/`setInterval` | Chromium | `DispatchWorkItem` + 主 runloop 泵 |
| `atob`/`btoa`/`URL`/`TextDecoder`/`fetch` | Chromium | 页面脚本里 ~50 行 polyfill |

桥的调用方向只有一条：Swift → JS 全局函数（`__lx_onTimer` / `__lx_onResponse` /
`__lx_invokeRequest`），比双向 JSValue 持有简单得多。

## 二、量到的数字

```
            进程启动 → JSC+glue 就绪     6.9 – 14.7 ms
            → 脚本求值完成               +0.8 ms
            → lx.send(inited)            +0.0 ms
            → musicUrl 落地               11 – 25 ms（本地后端）
                                          1.3 – 6.5 s（真实上游，取决于上游）
            RSS                          19.3 – 24.2 MB
```

对照：Q-music 每个音源是一个常驻隐藏 BrowserWindow，多个音源就是多个 Chromium
进程。这里是单进程内每音源一个 `JSContext`（同进程内多个 context 共享堆）。

## 三、兼容性

**20/20 脚本成功解析并执行**，**19/20 到达 `lx.send(inited)`**。唯一失败的 `juhe`
是它自己的后端返回 Cloudflare `error code: 1027`（该 IP 被封），与运行时无关。

取链抽查（`kg`，真实 hash `1f7e7659…`）：

| 脚本 | 结果 | 备注 |
|---|---|---|
| `lx` (64 KB) | ✅ 真实 mp3 | |
| `xinghai` (21 KB) | ✅ 真实 mp3 | 用到 `Buffer` 特性探测 |
| `xinglan` (74 KB) | ✅ 真实 mp3 | 用到 `aesEncrypt` + `md5` |
| `jiexiang` (91 KB) | ✅ 真实 mp3 | 用到 `aesEncrypt` + `md5` |
| `hyw` (12 KB) | ✅ 真实 mp3（酷我） | |
| `flower` | ✗ 上游返回 `Not Found` | 脚本自身链路失效 |
| `qingliang` | ✗ 5 条后端全挂（含超时） | 上游失效 |
| `sixyin` (333 KB) | ✗ 12 s 内未收敛 | 未测完，非报错 |

✅ 的地址都由 `--verify` 真实下载首 4 KB 并识别了音频头（ID3 / MPEG），不是只看字符串。

**关键正向证据**：`xinglan` / `jiexiang` 用 `lx.utils.crypto.aesEncrypt` + `md5` 做请求签名，
它们能出真实地址，说明 CryptoKit/CommonCrypto 的输出与 Node 字节级一致。夹具里
`aes-128-cbc` 的 hex 也和 `node -e` 的输出逐字节比对过。

## 四、50 个脚本的 API 面普查（决定桥要覆盖什么）

| 用法 | 脚本数 |
|---|---|
| `lx.request` / Promise 包装 | 全部 |
| `resp.body` / `statusCode` / `headers` | 22 / 16 / 12 |
| `lx.utils.buffer` | 8 |
| `md5` | 6 |
| `aesEncrypt` | 4 |
| `atob`/`btoa` | 6 |
| `fetch(` | 4（多数是内部方法名） |
| `new URL` | 4 |
| `Buffer.` / `document.` | 6 / 4（都是 `typeof` 守卫） |
| `lx.utils.zlib` | **0** |
| `resp.raw` / `resp.bytes` | **0** |
| `rsaEncrypt` | **0** |

现代音源绝大多数就是一个 `lx.request` + 字段提取的薄代理，深度密码学只出现在少数脚本里。

## 五、踩到的真实保真差异

1. **响应头大小写**：Q-music 走 `needle`，拿到的是 Node 已小写的头名；`URLSession`
   保留原始大小写。已改为小写输出，否则 `resp.headers['content-type']` 的脚本会静默失效。
2. **`Buffer` / `document` 在 Electron 主世界本来就不存在**。6 个脚本用 `typeof` 探测后
   走降级分支，行为与 Electron 一致；刻意不注入 `Buffer`，避免出现"比原版更宽松"的分叉。
3. **`lx.version` / `env`** 需固定为 `'2.0.0'` / `'desktop'`，有脚本拿它比对自身版本。
4. JSC 框架原生**没有** `URL`、`TextEncoder/Decoder`、`atob/btoa`、`fetch`、`setTimeout`
   （探测输出见每次运行的 `JSC builtins` 行）——这些必须自己补，Chromium 里是白送的。

## 六、还没验证的（不要当成已解决）

- `rsaEncrypt`（RSA_NO_PADDING）实现了但 **50 个脚本里 0 个调用**，没有真实样本验证。
- 代理支持（Q-music 的 `network.proxy.*` → `tunnel`）没做。
- `lx.send(updateAlert)`、`lx.request` 的 abort 语义只做了轻量测试。
- 每音源一个 `JSContext` 的隔离强度弱于每音源一个独立进程/独立渲染器：
  `JSContextGroup` 若共享堆，一个脚本的 OOM/死循环会波及全部。要隔离需给每个音源
  独立 `JSContextGroup` 甚至 XPC 子进程。
- 只测了 `musicUrl`；`lyric` / `pic` 走同一条桥但未跑真实脚本。
- 没有做与 Electron 版并排的耗时/RSS 对照（本机没装 Q-music 依赖），
  上述内存数字是单进程绝对值的下限参考，不是端到端对比。

## 七、复现

```sh
cd cadence
./run.sh                 # mock 后端 + 全表面夹具 + 真实的 helloworld 脚本
./run.sh matrix          # 20 个音源的兼容性普查
./.build/debug/lxspike <source.js> --source kg --quality 320k --musicinfo '<json>' -v
```

`--init-only` 只验证加载与初始化，`--no-verify` 跳过地址探测。

---

# Phase 1：原生 App（同日追加）

Phase 0 只证明"音源能脱离 Chromium"。Phase 1 把它做成了一个能听歌的 macOS App：
`Sources/Cadence/`，`./build-app.sh` 打出 `.build/Cadence.app`。
细节见 `README.md`，这里只记**新踩到的坑和新的数据**。

## 端到端链路（真实数据，非 mock）

```
source   latest.js (xinglan)                    # 74KB 社区音源，用到 aesEncrypt + md5
inited   星澜聚合音源 v4.0.2 sources=kg,kw,mg,tx,wy
search   发如雪 — 周杰伦 [1f7e7659b9fff4fb6f71562a61bbc25f]
resolve  320k 9690 ms  http://fsandroid.tx.kugou.com/...
lyric    69 lines, first @0.00s  周杰伦 - 发如雪
audio    duration 299.3s  format ok
playing  yes  position 2.23s
pause    ok
done     41348 ms total, 47.7 MB rss
```

跑法：`QMUSIC_SOURCE=<script.js> .../Cadence --selftest`。

## 新踩到的四个坑

1. **CRLF 歌词整份变一行**。Swift 把 `"\r\n"` 当作**单个 Character**，`split(separator: "\n")`
   拆不开；酷狗 LRC 是 CRLF + BOM，结果头部标签全被当成一句歌词。修法是先归一化换行再拆。
   这个坑只在 Swift 侧存在，Node/Electron 版永远不会遇到。
2. **`MainActor` 里 pump runloop 会饿死自己**。在同步的 `@MainActor` 函数里
   `RunLoop.main.run(...)` 等 `Task { @MainActor }`，那个 Task 拿不到执行机会，快照永远是空态。
   改成真正的 `await` 才修复。（`--selftest` 一开始能用，只是因为它跑在非隔离上下文里。）
3. **`latest.js` 重名覆盖**。社区音源几乎都叫 `latest.js`，按文件名落盘会互相覆盖，
   导入第二个就顶掉第一个。改成内容不同则加后缀。
4. 响应头大小写（Phase 0 已修）在真实脚本上确实是有效差异，不是理论问题。

## 内存归因

| 成分 | RSS |
|---|---|
| 音源运行时（单进程 CLI） | 19–25 MB |
| App 壳（SwiftUI/AppKit/AVFoundation/MediaPlayer，未加载音源） | 118.9 MB |
| 每增加一个音源（JSC context + 脚本） | +21 MB |

**结论修正**：原生重写的内存优势不在壳，在**每个音源的成本**。
Q-music 每个音源是一个 Chromium 渲染进程（百兆级），这里是 20 MB；
但壳本身并不比 Electron 空转轻多少。想省内存，收益来自"多音源常驻"这个场景。

## 离屏验收的局限

`cacheDisplay` 和 `dataWithPDF` 都**不画 AppKit 桥接控件的文字**，
所以 `--snapshot` 出来的图里「搜索」按钮与音质下拉是空白胶囊。
图标、文本、列表、歌词面板都正常。真窗口交互仍需人工验收。

---

# Phase 2：多平台 + 下载 + mac 形态（同日追加）

## 平台覆盖（真实接口，非 mock）

| 平台 | 搜索 | 取链 | 歌词 |
|---|---|---|---|
| kg 酷狗 | ✅ `mobilecdn` | ✅ | ✅ |
| wy 网易云 | ✅ `api/search/get` | ✅ | ✅ |
| kw 酷我 | ✅ `search.kuwo.cn/r.s`（单引号 JS 字面量，需正则抽取） | ✅ | — |
| tx QQ 音乐 | ✅ `smartbox_new.fcg`（仅约 10 条） | ✅ `isure6.stream.qqmusic.qq.com` | ✅ |
| mg 咪咕 | ❌ 无匿名入口 | — | — |

`fish_music v1.9.0` 一把过三平台：kg FLAC 34.5 MB、kw FLAC24、tx FLAC，全部下载成功并播放。

## 这一轮踩到的坑

1. **逐字节下载太慢**。`for try await byte in bytes(for:)` 对 30–50 MB 的 FLAC 会拖到超时；
   换成 `URLSession.download(for:delegate:)`（磁盘直下 + 进度回调），kg 的 34.5 MB 在十几秒内完成。
2. **签名 URL 会过期**。自检里“先解析全部平台、再下载第一个”跑出了下载超时——
   因为轮到下载时 URL 的 TTL 已经过去了。真实实现里必须**解析完立刻下载**。
3. **SwiftUI 的 `@State` 在只有 CLT 的环境里编不过**：`@State` 已是宏，宏插件随完整 Xcode 提供。
   改用 `@StateObject` + 小状态袋（`SearchUIState` / `PlayerUIState` / `SourceUIState`）。
4. **离屏渲染的 appearance 是分裂的**：SwiftUI 内容跟随我们强制的 `.darkAqua`，
   AppKit 桥接控件跟随 `NSApp`/屏幕外观，于是出现“白底白字”。
   单独渲染控件（`-probe.png`）证明控件本身没问题，是捕获路径的限制。

## 界面

`NavigationSplitView`（发现/来源 两组侧栏）+ 统一工具栏 `.searchable` 搜索 + 平台分段控件 +
平台色徽标（KG 蓝 / WY 红 / KW 橙 / TX 绿）+ 底部播放条 + `Settings`（⌘,）+ ⌘D 下载。
桌面歌词仍是常驻 `NSPanel`，跟随播放进度高亮当前行。

---

# Phase 3：渐进流播放（同日追加）

## 做法

`AVAudioFile` 打开时会缓存长度，所以拿不到"正在变长的文件"。
方案：后台读循环每 ~10 秒重开一次文件，读自上次调度位置起新增的部分，
解码成 PCM 后 `scheduleBuffer` 到 `AVAudioPlayerNode`，缓冲维持在 8–20 秒，
因此重开文件不会造成断音。EQ / 变速仍在同一节点图上。

下载侧换成 `URLSessionDataDelegate` 增量写盘（不是 `downloadTask`，后者只给成品文件），
暴露 `bytesWritten` 给读循环；`expectedBytes` 用来显示进度和估算时长。

## 实测

```
stream   started in 0.69 s  (est. duration 270 s, downloaded 1%)   ← 52.8 MB FLAC
playing  position 2.98 s  buffered through 20.0 s  downloaded 100%
seek     → 15.0 s, now 16.0 s  (ok)
pause    ok
```

对比改造前：同一首 52.8 MB 要整首下完（约 7–12 秒）才开始出声。

## 又踩到的坑

1. **`@MainActor` 同步函数里 `RunLoop.main.run()` 再次饿死自己**（Phase 1 就踩过）：
   等读循环的首批 buffer 时用同步 pump 会卡住主线程最长 10 秒。改成 `async` + `Task.sleep`。
2. **播放期间进度条不动**：进度只在启动等待循环里刷新，`beginPlayback` 之后就再没更新；
   改到位置定时器里轮询下载器。
3. **seek 与读循环竞争**：读循环在主线程之外推进 `nextFrame`，seek 会把游标重置，
   正在解码的旧块可能被排进队列。加 `NSLock`，并在调度前校验游标未被移动。

---

# Phase 5：改名、隐喻化与体验优化（同日追加）

## 改名

产品名 **Cadence**（中文「韵律」），`Brand.swift` 是唯一来源；打包用 `CFBundleName=Cadence`。
平台显示名改为隐喻（鲸 / 焰 / 珀 / 萤），内部仍用 `kg/wy/kw/tx` 与音源协议对接。
改名不动数据目录，已有音源与下载不会失联。

## 这一轮的界面与优化

| 类别 | 改动 |
|---|---|
| 封面 | 双层缓存（内存 + 磁盘），设置里可看占用并清除；列表行只在搜索结果自带封面时才联网 |
| 歌词浮窗 | 当前行 23pt + 阴影，相邻 16/14pt 分档透明度，更远的加模糊；位置写入 UserDefaults，重开还在原处 |
| 进度条 | 自绘三段（底槽 / 已缓冲 / 已播放），拖动才显示圆点 |
| 加载/空态 | 骨架屏、教学式空状态、下载失败可重试 |
| 播放键 | 悬停底色加深 + 轻微放大 |
| 搜索 | 450ms 防抖 + 任务取消 + 结果归属校验 |
| 音源加载 | `withTaskGroup` 并行 |
| 下载 | 并发上限 3、排队、取消/重试/清空 |
| 记忆 | 平台、音质、侧栏、音量、EQ、窗口位置、歌词浮窗位置 |
| seek | 全曲可拖；超出缓冲时读循环等待数据并显示缓冲态 |
| 菜单栏 | 关窗不退出，图标随播放状态切换，菜单含传输控制与窗口唤回 |

## 关窗不退出：两次尝试的结论

1. 直接替换 `NSWindow.delegate` → 窗口能隐藏但唤不回来（SwiftUI 记账被打断）
2. `openWindow(id:)`（`WindowGroup` 与 `Window` 两种场景都试）→ 关掉的窗口不会重建
3. 最终方案：**转发代理**接管 `windowShouldClose`（隐藏而非关闭），其余选择器全部转发给
   SwiftUI 原 delegate；`show()` 同步 surface + 一次 async 补偿，避开状态菜单的追踪循环

验证：`--window-test` 输出 `intercepted=true hidden=true` → `visible=true sameWindow=true`。

---

# Phase 6：继续优化（同日追加）

## 这一轮

| 项 | 结果 |
|---|---|
| 歌词跨源回退 | 珀（酷我）从 0 行变成 53 行；任何源失手都会用焰匹配一次 |
| 系统正在播放 | 进度随播放刷新，控制中心可拖拽定位（`changePlaybackPositionCommand`） |
| seek 全曲 | 实测拖到 80%（169 s）→ `buffering=no`，`playing=yes`，位置正确 |
| 下载去重 | 同曲同音质不会重复排队 |
| 快捷键 | `⌘1/⌘2/⌘3` 切搜索 / 下载 / 音源 |

## 没做成的

QQ 全量搜索（想突破 smartbox 的 ~10 条）试了三个入口：

- `u.y.qq.com/cgi-bin/musicu.fcg`（`music.search.SearchCgiService`）→ `code 2001`
- 同接口 `ct=24, cv=0` → `code 0` 但 `list` 为空
- `u.y.qq.com/cgi-bin/musics.fcg` → `code 2000`

都要登录态（`uin` + `qqmusic_key`）。在不做账号体系的前提下，萤（QQ）只能维持 smartbox 的少量结果。

---

# Phase 7：内部命名收尾 + 链接导入修复（同日追加）

## 改名收尾

产品名之外，工程内部也全部去掉了 `QMusicNative`：

- SwiftPM package target/product: `QMusicNative` → `Cadence`，目录 `Sources/Cadence`
- 可执行文件 `Contents/MacOS/Cadence`，`CFBundleIdentifier = dev.cadence.player`
- 数据/缓存/下载目录、Logger subsystem、自检入口字符串一并更新
- `Migration.swift` 首次启动搬家，实测：
  - `Application Support/Cadence/Sources` + `sources.json` 就位
  - `~/Music/Cadence/鲸/`（原 `Q Music/酷狗/`）里的 flac 原样保留
  - `downloadDirectory` 从旧路径改写成 `~/Music/Cadence`
  - 旧 bundle 域仍留在磁盘上（无害，可手动 `defaults delete`）

## 链接导入弹窗卡住的修复

用户反馈「导入后弹窗不消失」。实测数据把方向指清楚了：

```
import   0.44 s   (4 KB 脚本)     max main-thread stall 21 ms
import   13.42 s  (640 KB 脚本)   max main-thread stall 51 ms
```

主线程几乎不卡，所以不是求值阻塞；13 s 是脚本自己的初始化握手。
真正脆弱的是**弹窗状态挂在视图的 `@StateObject` 上**——导入触发 `loadedSources`
更新会重建视图，若状态对象被换新，`showingImport = false` 就落到了新实例上，
SwiftUI 那边仍然认为 sheet 是 presented。

修法：

1. 弹窗状态搬到 `AppState`（`showingImportSheet` / `importURL`），不再随视图重建丢失
2. 按钮先关弹窗，再用 `Task` 异步导入，导入期间在页头显示「正在初始化音源…」
3. `loadSourcesFromDisk()` 用清单跳过未变化脚本，导入后只解析新增的那一个

---

# Phase 8：导入改用内联行（弹窗卡住的根治）

## 现象

用户截图：导入**成功**（列表多了一项、状态栏显示「已导入…」），但「从链接导入音源」的
sheet 还在，输入框里的链接也还在。

## 排查

1. 先量了主线程阻塞：`--import-test` 显示 640 KB 脚本导入总耗时 13.4 s，
   **主线程最长只卡 51 ms**，所以不是求值把 UI 冻住，13 s 是脚本自己的初始化握手。
2. 把弹窗状态从视图的 `@StateObject` 挪到 `AppState`（`showingImportSheet`）——
   按截图看仍未解决：`showingImportSheet = false` 和 `importURL = ""` 都没落地，
   而同样挂在 `AppState` 上的 `message`、`loadedSources` 却更新了。
   说明问题不在数据层，而在 **SwiftUI 的 sheet presentation**：导入刷新 `loadedSources`
   会让 `SourcesPane` 重建，presentation 跟着丢。
3. `--sheet-test` 还测出一件事：在非交互会话里 SwiftUI 的 sheet **根本不会被创建**
   （`NSApp.windows` 里没有任何 sheet 窗口），这类生命周期问题很难在测试里覆盖。

## 结论与修法

一个「粘贴链接 → 下载 → 加载」的动作不需要模态。改成**内联输入行**：

- 点「从链接导入…」在音源页展开一行：`链接输入框 + 导入 + 取消`
- 回车即导入；提交时先关行、清空输入，再异步导入
- 页头在导入期间显示「正在初始化音源…」，不阻塞任何操作

没有 presentation 生命周期，就没有"关不掉"这一类 bug。

验证：

```
$ Cadence --sheet-test
row       visible=true
row       after submit: visible=false url=''
imported  2 → 3  message=已导入 大鱼吃小鱼v1.9.0.js
result    PASS  (row closed, url cleared, source added)
```

---

# Phase 9：图标重做 + 内存实测（同日追加）

## 图标

Dock 图标重画为「三根均衡器条」，和界面里"正在播放"那三根跳动条同源；
菜单栏图标在播放时切成 `waveform`。`LSApplicationCategoryType = public.app-category.music`。

## 内存实测（--idle-probe）

```
t+0    engines=1  rss=150 MB     ← 刚加载 640 KB 音源
t+25   engines=1  rss=161 MB     ← 脚本定时器在跑
t+50   engines=1  rss=174 MB
idle   engines=0  rss=177 MB     ← 90s 闲置释放引擎（实测 45s 版同结论）
```

结论（如实记录）：

- 释放引擎后 `engines=0`，但 **RSS 不回落**：JSC 堆还给分配器了，macOS 不把页还给系统；
  `malloc_zone_pressure_relief` 也无效。收益是**停止增长 + 脚本定时器停下**，不是数字变小。
- 真正的开销结构：SwiftUI/AppKit/AVFoundation/MediaPlayer 基线 ~143 MB，
  一个 640 KB 音源引擎 ~25 MB 且会缓慢爬升，封面缓存封顶 ~10 MB（48 张 / ≤256 px）。
- 回收策略：闲置 90 s、菜单栏模式 30 s；保留期间不重复解析。
- `播放中（无窗口自检）= 78–81 MB`。

## 顺带修的空状态

`EmptyState` 用 `.background(Circle().fill(...))` 叠图标，在离屏/分层渲染下圆底变实心、
图标丢失。改成 `ZStack { Circle; Image }`，两种渲染路径一致。
