# ESP8266 AI 状态时钟

一个 ESP8266 WiFi 时钟固件：显示时间 + Claude Code / Codex CLI / kimi-code 的实时工作状态和用量。
不需要任何官方账单 API key —— 数据来自本地已有的来源：

- **工作状态**（working/idle/offline）：本地会话日志的新旧程度
  - `~/.claude/projects/**/*.jsonl`（Claude Code 会话记录）
  - `~/.codex/sessions/**/*.jsonl`（Codex CLI 会话记录）
  - `~/.kimi-code/sessions/**/wire.jsonl`（kimi-code 会话记录）
- **真实额度**（5h / 周窗口用量百分比 + 重置时间）：复用 Claude / Codex 两个 CLI 已经存在本机的
  OAuth 登录凭据，直接调各自官方用量接口（做法与
  [CodexBar](https://github.com/steipete/CodexBar) 相同，token 只发给各自官方 API）：
  - Claude：Keychain 里的 `Claude Code-credentials` → `api.anthropic.com/api/oauth/usage`
  - Codex：`~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`
  - kimi-code：目前没有公开的用量接口，额度显示“额度未知”

架构：`mac-app/` 是一个 **Swift 原生菜单栏 app**（Windows 用户用 `windows-app/`，
功能一致的 C# 托盘移植版），读日志、开一个本地 HTTP 服务；
`firmware/` 是 ESP8266 固件，联网后每 15 秒轮询这个服务，把时间 + 状态画到 240x240
ST7789 彩屏上。桌宠动画（GIF）的上传和解码**全部在 ESP8266 板子上完成**，换形象不再需要
电脑参与（详见第 4 节）。

## 目录结构

```
mac-app/      Mac 原生菜单栏 app (Swift / SPM，仅用系统框架，无第三方依赖)
windows-app/  Windows 托盘 app (C# / .NET 8 WinForms)，功能与 mac-app 一致（见其 README）
firmware/     ESP8266 固件 (PlatformIO + Arduino framework)，含板上 GIF 解码
tools/        GIF -> RGB565 默认精灵图头文件的转换脚本（改编译进固件的默认动画时用）
```

## 1. 跑起 Mac 端菜单栏 app

> Windows 用户：功能一致的托盘版见 [`windows-app/README.md`](windows-app/README.md)，
> 本节其余说明（左右键交互、自动配对、数据来源）同样适用。

需要 Xcode / Swift 工具链（macOS 自带 `swift`）。

```bash
cd mac-app
swift run                # 前台运行；或 swift build 后跑 .build/debug/AIClockBridge
```

菜单栏会出现一个**复古麦金塔小电脑图标**（代码画的模板图，自动适配深浅色菜单栏，
不占宽度显示额度数字）：

- **左键点击** → 弹出 ESP8266 屏幕的**实时镜像**：Mac 端用与固件完全相同的数据
  重绘同一个画面（方形额度环 + 当前桌宠动画 + logo + 额度文字），动画帧直接从设备
  `GET /sprite/<app>/raw` 拉取（设备正在用什么就播什么，自定义/内置都一样），
  working 时同步播放走路循环，随设备 2s/6s 切换同步换角色；底部附
  自动/Claude/Codex 快速切换。
- **右键点击** → 控制菜单：完整额度（5h/周 用量 + 重置倒计时）+ 设备遥控：

- **自动查找并配对设备**：一般不用手动——设备本来就在轮询本机的 `/status`，
  bridge 记下来访 IP 即完成发现（零扫描）；地址为空时自动配对，设备 DHCP 换了 IP
  也会自愈。菜单项走完整流程：最近来访 IP → 已配置地址复验 → 子网 /24 扫描兜底
  （覆盖"刚配完 WiFi、还没设过桥接"的全新设备）。
- **设置设备地址…**：手动填时钟的 IP（开机时屏幕会显示；有自动配对后基本用不上）
- **屏幕显示**：自动（谁在干活显示谁）/ 固定 Claude / 固定 Codex / 固定 Kimi
- **音乐播放**：显示 Mac 当前播放的专辑封面、歌曲、歌手和进度
- **更换桌宠动画…**：内置 [petdex.dev](https://petdex.dev) 画廊（3300+ 开源桌宠），
  搜索 → 选动画（待机/跑步/挥手…9 种）→ 预览 → 一键上传到设备
- **恢复默认动画**：删掉自定义 GIF，回到固件内置形象
- **把本机设为设备桥接**：一键把设备的 Bridge host 指到这台 Mac

验证服务是否正常：

```bash
curl -s http://localhost:8765/status | python3 -m json.tool
```

已验证返回示例（真实数据）：

```json
{
  "claude": {"status": "working", "tokens_today": 4868001, "session_min": 26, "session_window_min": 300},
  "codex":  {"status": "offline", "tokens_today": 61471, "primary_pct": 1.0, "primary_window_min": 300,
             "primary_reset_min": 0, "weekly_pct": 2.0, "weekly_window_min": 10080, "weekly_reset_min": 8729},
  "kimi":   {"status": "idle", "tokens_today": 12500, "session_min": 0, "session_window_min": 300,
             "five_hour_pct": null, "five_hour_reset_min": null,
             "seven_day_pct": null, "seven_day_reset_min": null, "needs_input": false}
}
```

想要开机自启：`swift build -c release` 得到 `.build/release/AIClockBridge`，把它包成
LaunchAgent（`~/Library/LaunchAgents/`）即可，未内置，按需再加。

**注意**：HTTP 服务监听 `0.0.0.0:8765`，同一局域网内的设备都能读到（只是状态和 token
计数，不含任何 API key），如果在意，建议只在家庭可信网络下跑，或用系统防火墙限制。

### 数据来源与局限

- **额度（两家都是真实值）**：app 每 2 分钟调一次官方用量接口（见开头），拿到
  5h / 周窗口的已用百分比和重置时间，合并进 `/status` 下发给设备。接口 429 限流时
  自动退避 5 分钟并沿用上一次的数值。
- Claude 的 OAuth token 存在 Keychain，app 通过 `security` CLI 读取，第一次运行
  macOS 可能弹一次授权框（选"始终允许"即可）；`~/.claude/.credentials.json` 存在时
  优先读文件。
- 若凭据缺失/过期，额度显示"?"，工作状态仍照常工作（来自日志，不依赖网络）。

## 2. 烧录 ESP8266 固件

已确认的硬件：ESP8266EX（ESP-12S 模组）/ 4MB flash / CH340C 转串口，设备节点
`/dev/cu.usbserial-130`。这是拼多多"WiFi天气时钟 MG01"成品板，本质是 oshwhub 上
["SD2/小电视"开源方案](https://oshwhub.com/q21182889/sd2) 的量产版。

**接线是厂家固定的，一体成型无法重接**，网上能搜到的几份"看起来像"的教程接线图实测
都是错的——真正正确的引脚来自该开源项目附带的厂家参考固件源码
（`TFT_eSPI/User_Setup.h` + `SmallDesktopDisplay.ino`），已在实机验证点亮：

| 屏幕引脚 | 说明 | ESP-12S | GPIO |
|---|---|---|---|
| SCLK | SPI 时钟 | D5 | GPIO14（硬件 SPI）|
| MOSI | SPI 数据 | D7 | GPIO13（硬件 SPI）|
| CS   | 片选 | D8 | GPIO15 |
| DC   | 数据/命令选择 | D3 | GPIO0  |
| RESET| 复位 | D4 | GPIO2  |
| 背光 | LED 背光，**低电平点亮**，厂家固件用 PWM 调光 | D1 | GPIO5  |
| VCC  | 电源 | 3V3 | - |
| GND  | 地 | GND | - |

驱动型号也有讲究：要用 TFT_eSPI 的 `ST7789_2_DRIVER`（一个专门的简化初始化变体），
用普通的 `ST7789_DRIVER` 配合正确引脚依然点不亮。`platformio.ini` 里已经按这个组合
配置好了。

如果你买到的是完全不同的板子，改 `firmware/platformio.ini` 里 `build_flags` 的
`TFT_*` 几行即可；但如果就是这款"WiFi天气时钟 MG01"，直接用现在的配置就行，不用再猜。

```bash
cd firmware
python3 -m venv .pio-venv && source .pio-venv/bin/activate
pip install platformio
pio run -t upload          # 已验证：编译成功，Flash 45.7%，RAM 39.7%
```

烧录后串口会打印调试日志（这版固件不再是"静默"的）：

```
[wifi] starting WiFiManager autoConnect...
*wm:AutoConnect
*wm:No wifi saved, skipping
*wm:StartAP with SSID:  AI-Clock-Setup
*wm:AP IP address: 192.168.4.1
```

首次开机（或 WiFi 配置丢失时）会开一个热点 `AI-Clock-Setup`，手机连上后自动弹出配置页
（或手动访问 `192.168.4.1`），选择你的 WiFi，并在 "Bridge host (ip:port)" 里填这台 Mac
的局域网 IP，例如 `192.168.1.23:8765`。保存后设备会记住配置（存在 LittleFS 里），下次
开机自动连线。

查看串口日志：

```bash
pio device monitor -b 115200
```

## 3. 屏幕布局

全屏单应用视图（不显示时钟），一次只显示 Claude / Codex / Kimi 其中一个，规则：

- **只有一方在工作** → 固定显示正在工作的那个
- **多方都在工作** → 每 2 秒交替
- **都空闲** → 每 6 秒慢速交替
- Mac 菜单栏里也可以强制固定显示某一方（`POST /api/display`），固定后忽略上述规则

视觉元素：

- 屏幕中央：对应角色的大幅像素动画（Claude = 跑步的 Dario，Codex = 戴耳机的宠物，
  Kimi = 银月角色），仅在该角色 `working` 时播放动画，否则停在静止帧。
- 屏幕四周一圈方形进度环：环的填充长度 = 用量百分比（Claude 用 5 小时滚动窗口已用
  比例近似，Codex 用真实的 5h `primary_pct`）；环的颜色/动画参考
  [vibecoding-signal-light](https://github.com/starlight36/vibecoding-signal-light)
  的红绿灯设计：
  - **常亮绿** = 空闲/离线，不需要关注
  - **绿→黄→红缓慢循环** = 正在工作
  - **红色闪烁**（最高优先级，覆盖其他状态）= 桥接服务连不上或数据过期（超过
    2 个轮询周期没更新），需要马上看一眼
- **整圈边框红色闪烁 = 需要你确认操作**：Claude / Codex / Kimi 弹出权限/审批选择时（Claude
  的 `Notification`、Codex / Kimi 的 `PermissionRequest` / `Elicitation` hook），设备整圈边框红色闪烁提醒你去
  确认；AUTO 模式还会自动切到那个待审批的角色（优先级高于音乐自动切换）。你在 CLI 里
  做出选择后（下一个工具调用/回合事件到达）自动停止闪烁，5 分钟无响应也会自动超时清除。
  Mac 弹窗镜像同步显示红色边框闪烁。

## 4. 自定义桌宠形象

两个入口，推荐 Mac 菜单栏（petdex 画廊 + 预览），设备网页作为兜底：

1. **Mac 菜单栏 →「更换桌宠动画…」**：从 [petdex.dev](https://petdex.dev) 的公开
   manifest（`assets.petdex.dev/manifests/petdex-v1.json`，3300+ 开源桌宠）搜索选择。
   每个桌宠是一张 1536x1872 的 WebP 精灵图（8 列 x 9 行，每帧 192x208，每行一种动画：
   待机/左右跑/挥手/跳跃/失败/等待/原地跑/思考）。app 在本地裁出所选动画行、缩放到
   目标插槽尺寸、合成黑底循环 GIF，然后 POST 到设备的 `/sprite/claude|codex|kimi`。
2. **设备网页** `http://<设备IP>/`：手动上传任意 `.gif`，适合用自己的图。

两条路最终都走同一条链路：设备收到 GIF 后**自己在板上解码并缩放**，立刻替换该角色的
动画，重启后也记得，**不需要重新编译或烧录固件**。

### 设备 HTTP API（Mac app 用的就是这套）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/info` | 设备状态 JSON：ip/ssid/bridge/显示模式/当前显示/自定义精灵标记 |
| POST | `/api/display` | `mode=auto\|claude\|codex\|kimi\|net\|music` 切换屏幕显示（net=网速曲线页，music=音乐播放页）|
| POST | `/api/bridge` | `host=ip:port` 设置桥接地址 |
| POST | `/sprite/claude`、`/sprite/codex`、`/sprite/kimi` | multipart 上传 GIF 并板上解码替换 |
| POST | `/sprite/claude/reset`、`/sprite/codex/reset`、`/sprite/kimi/reset` | 删除自定义动画，恢复内置形象 |
| GET | `/sprite/claude/raw`、`/sprite/codex/raw`、`/sprite/kimi/raw` | 当前生效动画的原始帧流 `[1B帧数][RGB565大端帧...]`（镜像窗口用）|

`/api/info` 里的 `sprite_rev` 在每次上传/重置动画后自增，镜像端据此决定是否重新拉帧。

## 5. 网速曲线页（Mac + 设备同步显示）

Mac app 每 250ms（4Hz）读一次内核的网卡字节计数（getifaddrs/AF_LINK，只统计物理
`en*` 网卡，避免 VPN/utun 重复计数），保留 3 分钟历史。

显示模式切到「网速曲线」后，设备端**渲染与网络完全解耦**：`GET /net` 返回带全局
序号（seq）的最近 12 个 250ms 样本，设备每 2 秒拉一次补进队列（按 seq 去重），
渲染以固定 250ms/列的节奏消费队列，HTTP 延迟不会体现在画面上。

界面是任务管理器风格的**滚动填充面积图**（224 列 x 128px，56 秒窗口，最新在右）：
下载 = 暗绿填充 + 亮绿顶边，上传 = 2px 黄线，背景 25/50/75% 暗格线；整图共享一个
1/2/5 阶梯的"整数量程"（10K/20K/50K/…），高度全图可比，量程标签显示在图外右上。
每帧从 224 个样本的数据环逐行合成像素、每行一次 `pushImage` 整行写屏——没有
"先清屏再画"的过程，所以完全无闪烁。顶部大号 DL/UL 读数取 1 秒平均，只在数值
变化时局部重绘。Mac 弹窗镜像用同一套数据模型和布局同步渲染。

Mac 端常驻进程由 LaunchAgent（`~/Library/LaunchAgents/local.AIClockBridge.plist`，
每 60 秒拉活 `mac-app/.build/AIClockBridge.app`）管理；**改代码后要把新二进制和
资源包同步进这个 .app**（`cp .build/debug/AIClockBridge .build/AIClockBridge.app/Contents/MacOS/`），
否则 LaunchAgent 会不断复活旧版本、和手动启动的新版本抢 8765 端口轮流应答。

## 6. 音乐播放页（Mac + 设备同步显示，自动切换）

**AUTO 模式下自动切换**：Mac 一有音频在播放（放歌、看视频都算），设备自动切到音乐
页；停止后自动切回桌宠/额度页。机制：`/status` 带 `music_playing` 字段（状态轮询
5 秒一次 → 开始播放约 5 秒内切入），音乐页显示时靠 `/music` 的 2 秒轮询快速检测停止
（约 2 秒切回）。仅 AUTO 生效；手动固定某模式（含固定「音乐播放」）时不受影响。
`/api/info` 里 `mode` 是配置的模式、`effective` 是当前实际渲染的模式，Mac 镜像按
`effective` 跟随。


显示模式切到「音乐播放」（弹窗底部分段控件 / 右键菜单 / `POST /api/display mode=music`）
后，Mac app 通过系统 Now Playing 信息读取当前播放的歌曲、歌手、播放进度和专辑封面，
桥接服务提供：

- `GET /music`：歌曲、歌手、专辑、播放状态、进度、封面版本号
- `GET /music/cover.raw`：128x128 RGB565 封面原始像素，设备逐行读取后直接绘制

设备每 2 秒刷新一次音乐信息；封面只有在版本号变化时重新拉取。Mac 弹窗镜像同样显示
音乐页，方便不用看设备也能确认布局。

## 7. Hooks 实时状态（秒级，参考 clawd-on-desk 的做法）

除了日志 mtime 轮询（保留为兜底），bridge 还接收三个 CLI 官方 hooks 的事件推送，
状态切换从"最多迟滞 20 秒"变成"毫秒级"：

- bridge 新增 `POST /event`，body：`{"agent":"claude|codex|kimi","event":"PreToolUse"}`
- `~/.claude/settings.json` 已注册 8 个事件的 curl hook（UserPromptSubmit/PreToolUse/
  PostToolUse/Stop/SessionEnd/Notification/PreCompact/SubagentStop，每条 `-m 1` 超时，
  不会拖慢 Claude Code；与已有 hooks 共存，靠命令里的 `8765/event` 标记幂等）
- 映射：UserPromptSubmit/Pre/PostToolUse 等 → working（TTL 10 分钟，覆盖长工具调用）；
  Stop/Notification 等 → idle（TTL 60 秒，只用来立刻压掉 mtime 的"工作尾巴"）
- Codex 侧已写入 `~/.codex/hooks.json` + `config.toml [features] hooks = true`，
  但 Codex 要求在 TUI 里跑一次 `/hooks` 信任新命令后才生效；未信任前走 mtime 兜底。
- Kimi 侧在 `~/.kimi-code/config.toml` 里注册 hooks（示例见下），kimi-code 启动时会
  自动加载；未配置时同样走 mtime 兜底。
- 局限：事件是全局的不分会话——A 会话 Stop 会把还在干活的 B 会话压成 idle 最多 60 秒
  （B 的下一个工具调用事件会立刻翻回 working）。

### kimi-code hooks 配置示例

在 `~/.kimi-code/config.toml` 里加入：

```toml
[hooks]
enabled = true

[[hooks.commands]]
event = "UserPromptSubmit"
command = "curl"
args = ["-m", "1", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"agent":"kimi","event":"UserPromptSubmit"}', "http://127.0.0.1:8765/event"]

[[hooks.commands]]
event = "PreToolUse"
command = "curl"
args = ["-m", "1", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"agent":"kimi","event":"PreToolUse"}', "http://127.0.0.1:8765/event"]

[[hooks.commands]]
event = "PostToolUse"
command = "curl"
args = ["-m", "1", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"agent":"kimi","event":"PostToolUse"}', "http://127.0.0.1:8765/event"]

[[hooks.commands]]
event = "Stop"
command = "curl"
args = ["-m", "1", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"agent":"kimi","event":"Stop"}', "http://127.0.0.1:8765/event"]

[[hooks.commands]]
event = "PermissionRequest"
command = "curl"
args = ["-m", "1", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"agent":"kimi","event":"PermissionRequest"}', "http://127.0.0.1:8765/event"]

[[hooks.commands]]
event = "Elicitation"
command = "curl"
args = ["-m", "1", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"agent":"kimi","event":"Elicitation"}', "http://127.0.0.1:8765/event"]
```

### GIF 上传架构

架构：GIF 通过 `ESP8266WebServer` 的 multipart 文件上传（`HTTPUpload` 回调）边收边流式
写进 LittleFS 的临时文件（`/c.gif` / `/x.gif` / `/k.gif`），然后固件用
[AnimatedGIF](https://github.com/bitbank2/AnimatedGIF) 库**逐行解码**成设备要的 RGB565
帧，写入 `/c.bin` / `/x.bin` / `/k.bin`（格式 `[1字节帧数][各帧像素...]`），最后删掉临时 GIF。

ESP8266 总共只有 ~80KB RAM，一帧 120x120 的 RGB565 就 ~28KB，AnimatedGIF 自己也要
~24KB，两个大缓冲塞不下，所以整条链路都是**逐行流式、不常驻整帧**：

- 上传：multipart 分块写文件，不把整个 body 攒进一个 `String`（那样体积必炸内存）。
- 解码：AnimatedGIF 逐行回调，只用两条「一行」缓冲把源行最近邻缩放到目标尺寸，直接
  逐行写进 `.bin`；不覆盖到的区域用**上一帧**补齐（读回刚写进 `.bin` 的上一帧），
  这样被优化器裁成小矩形的 GIF（disposal method 1）也能拼对。解码期间才在堆上
  临时 `new` 出 AnimatedGIF，用完就 `delete`。
- 显示：每次也只把「当前要画的一帧」从 LittleFS 逐行读出来 `pushImage`，不整帧驻留内存。
- 没有自定义素材时，退回固件里编译好的默认动画（`firmware/include/img/*.h`）。

**注意事项 / 局限**：

- GIF 太大（尺寸很大、颜色/帧很多）可能因内存不足解码失败，页面会报错，换小一点的即可。
- 目标插槽尺寸固定：Claude 111x120、Codex 120x120、Kimi 120x120，板上会最近邻缩放匹配（质量不如
  PIL 的 LANCZOS，像素风 GIF 通常没问题）。
- 最多取 GIF 的**前 8 帧**（没有整体帧数信息，就不做均匀抽帧了）。
- disposal method 2（"恢复到背景色"）没有单独区分，未覆盖像素保留上一帧而不是清空；
  对循环角色动画来说无所谓。
- WiFi 上传大文件偶尔会瞬时掉线（broken pipe 之类），失败重新上传一次即可。

## 已知限制 / TODO

- 参考项目里的“黄色闪烁-需要处理”“红色闪烁-需要批准”这类更细的状态，目前本地日志
  拿不到可靠信号，没有实现，只做了 working/idle-离线/桥接离线 三档。
- Mac 端 app 无鉴权，HTTP `/status` 监听 `0.0.0.0:8765`，仅建议在可信局域网使用；
  设备的 HTTP API 同样无鉴权。
- Claude 用量接口有较严格的服务端限流（429），app 已做 60s 节流 + 429 后 5 分钟退避 +
  沿用旧值，偶尔菜单里额度会显示为几分钟前的数据。
- 未做开机自启 LaunchAgent，需要的话可以再加（见第 1 节）。
- 改**默认**编译进固件的动画（`firmware/include/img/claude_sprite.h` /
  `codex_sprite.h` / `kimi_sprite.h`）仍可用 `tools/convert_sprites.py` 生成新的 `.h` 后 `pio run -t upload`；
  日常换形象用菜单栏 petdex 选择器或设备网页即可，无需烧录。
- 新增 Kimi 支持后，ESP8266 固件需要重新烧录一次；Mac / Windows bridge 端升级后无需烧录。
