# AIClockBridge for Windows

`mac-app/` 菜单栏桥接的 Windows 移植版：同一套功能、同一套设备协议（固件感知不到
桥接跑在哪个系统上），以系统托盘图标形式常驻。

功能与 Mac 版一致：

- **左键托盘图标** → ESP8266 屏幕实时镜像（额度环 + 桌宠动画 + 网速图 + 音乐页，
  与设备渲染同一份数据），底部附 自动/Claude/Codex/网速/音乐 快速切换
- **右键托盘图标** → 控制菜单：Claude/Codex 完整额度（5h/周 + 重置倒计时）、
  自动查找并配对设备、设置设备地址、屏幕显示模式、petdex 桌宠画廊、恢复默认动画、
  把本机设为设备桥接、桥接服务地址
- 可在托盘菜单选择绑定网卡；设备搜索、桥接 IP、设备请求和网速统计统一使用所选网卡
- 本地 HTTP 服务监听所选网卡与 `127.0.0.1:8765`：`/status`、`/net`、`/music`、`/music/cover.raw`、
  `/music/text.raw`、`POST /event`（Claude Code / Codex hooks 秒级状态推送）
- 数据来源同 Mac 版：`%USERPROFILE%\.claude\projects` / `%USERPROFILE%\.codex\sessions`
  的 JSONL 日志 + 各自官方用量接口（凭据读
  `%USERPROFILE%\.claude\.credentials.json` 和 `%USERPROFILE%\.codex\auth.json`，
  token 只发给各自官方 API）
- 音乐页读系统级 Now Playing（WinRT `GlobalSystemMediaTransportControlsSessionManager`，
  Spotify / 浏览器 / 本地播放器都能识别）；网速取绑定网卡的字节计数并以 4Hz 采样，
  自动模式优先选择带默认网关的物理网卡，也可显式选择 VPN/虚拟网卡

与 Mac 版的差异：

- 无固件刷写入口（刷写请用网页版刷写工具）
- 唯一的第三方依赖是 [ImageSharp](https://github.com/SixLabors/ImageSharp)——
  System.Drawing 解不了 petdex 的 WebP 精灵图、也编不了多帧 GIF

## 构建 / 运行

需要 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)（Windows 10
19041+ / Windows 11）：

```powershell
cd windows-app\AIClockBridge
dotnet run                # 前台运行（托盘出现小电脑图标）
# 或发布单文件：
dotnet publish -c Release -r win-x64 --self-contained false
# 产物在 bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\AIClockBridge.exe
```

首次启动 Windows 会弹防火墙授权（HTTP 服务监听所选网卡的 8765 端口，设备要从局域网访问，
选"允许"）。

**开机自启**：`Win+R` → `shell:startup` → 把 `AIClockBridge.exe` 的快捷方式放进去。

**Hooks 实时状态**（可选，同主 README §7）：Claude Code / Codex 的 hooks 往
`http://127.0.0.1:8765/event` POST 事件即可，Windows 下 curl 自带。

## 验证

```powershell
curl.exe -s http://localhost:8765/status | python -m json.tool
```

配置持久化在 `%APPDATA%\AIClockBridge\settings.json`（设备地址等）。

## 代码结构

| 文件 | 对应 Mac 版 | 说明 |
|---|---|---|
| `Program.cs` | `main.swift` | 入口 + 路由表 + 被动发现 |
| `TrayAppContext.cs` | `MenuBarController.swift` | 托盘图标 + 控制菜单 |
| `MirrorForm.cs` | `MirrorPopover.swift` | 240x240 屏幕镜像弹窗 |
| `PetPickerForm.cs` | `PetPickerWindow.swift` | petdex 桌宠选择器 |
| `PetdexService.cs` | `PetdexService.swift` | manifest / 精灵图 / GIF 合成 |
| `StatusService.cs` | `StatusReader.swift` | JSONL 日志扫描 + hook 事件 |
| `UsageFetcher.cs` | `UsageFetcher.swift` | 官方额度接口 |
| `NetSpeedMonitor.cs` | `NetSpeedMonitor.swift` | 4Hz 网速采样环 |
| `NowPlayingMonitor.cs` | `NowPlayingMonitor.swift` | 系统 Now Playing + 封面/文字条 RGB565 |
| `DeviceClient.cs` | `DeviceClient.swift` | 设备 HTTP API + 自动配对/子网扫描 |
| `MiniHttpServer.cs` | `HTTPServer.swift` | 所选网卡 + 127.0.0.1:8765 极简 HTTP 服务 |
| `Rgb565.cs` | （MirrorPopover 内联） | RGB565 大端编解码 |
