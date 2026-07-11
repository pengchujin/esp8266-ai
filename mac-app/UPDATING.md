# AIClockBridge 自动更新机制

macOS 桥接端使用 [Sparkle](https://sparkle-project.org/) 实现应用内检查/下载更新，用户无需手动删除重装。

## 设计原则（方案 A：纯本地）

- **与 GitHub 上游源码仓库完全隔离**：不依赖任何远程服务器、GitHub Release 或外部 CDN。
- **本地 vendoring**：Sparkle 框架已下载到 `mac-app/.build/artifacts/sparkle/`，后续构建不再访问网络。
- **自带 HTTP 服务器**：app 启动后在 `127.0.0.1:8765` 暴露一个本地 HTTP 服务，把 `~/Library/Application Support/AIClockBridge/updates/` 目录 serve 给 Sparkle。
- **本地 Ed25519 签名**：更新包用本地生成的密钥对签名，公钥编译进 app，私钥只留在这台 Mac。

默认 feed URL：

```
http://localhost:8765/updates/appcast.xml
```

## 版本号

唯一版本源：`mac-app/Sources/AIClockBridge/AppVersion.swift`

```swift
enum AppVersion {
    static let short = "1.3.1"
    static let build = "2"
}
```

发版前只改这一处，构建脚本会自动把相同值写入 `.app` 的 `Info.plist`。

## 界面

右键点击菜单栏图标：

- 菜单底部会显示当前 **版本号**。
- 鼠标悬停在菜单栏图标上也会显示版本号。
- **关于 AIClockBridge**：显示当前版本号、build 号、检查更新按钮。
- **检查更新…**：手动触发 Sparkle 检查。

Sparkle 默认还会在启动后自动检查（`SUEnableAutomaticChecks` 已启用）。

## 发布新版本

1. 改版本号：
   ```swift
   static let short = "1.3.2"
   static let build = "3"
   ```

2. 执行发布脚本：
   ```bash
   cd mac-app
   ./release.sh
   ```

   产物会发布到本地更新目录：
   - `~/Library/Application Support/AIClockBridge/updates/appcast.xml`
   - `~/Library/Application Support/AIClockBridge/updates/AIClockBridge-1.3.2.app.zip`

3. 当前已安装的 app 会在下次自动/手动检查更新时发现新版本，下载、替换并自动重启。

## 本地签名密钥

首次发布前需要生成本地签名密钥：

```bash
cd mac-app
./generate-update-keys.sh
```

生成的文件：

| 文件 | 用途 | 是否加入版本控制 |
|------|------|------------------|
| `update-keys/private.pem` | OpenSSL PEM 格式私钥 | ❌ 不要提交 |
| `update-keys/private.seed.b64` | Sparkle `sign_update` 需要的 32 字节种子 base64 | ❌ 不要提交 |
| `update-keys/public.b64` | Ed25519 公钥，编译进 `Info.plist` 的 `SUPublicEDKey` | ❌ 不要提交 |

整个 `update-keys/` 目录已加入 `.gitignore`，保持 purely local。

> 注意事项：
> - 同一台 Mac 上构建的 app 和发布的更新使用同一对密钥，互相兼容。
> - 换机器、重装系统或重新生成密钥后，旧密钥签名的更新包将无法通过新 app 的校验，需要重新发布。
> - 如果私钥泄露或更换，所有用旧密钥签名的更新都会失效。

## 本地测试完整更新流程

1. 确保当前已安装 app 版本低于要发布的版本。
2. 发布新版本（见上）。
3. 创建触发文件，让已安装 app 启动后自动打开 Sparkle 检查窗口：
   ```bash
   touch ~/Library/Application\ Support/AIClockBridge/.check_update_now
   ```
4. 启动 `/Applications/AIClockBridge.app`。
5. 等待 Sparkle 弹窗，点击下载/安装，观察 app 自动重启后版本号变化。
6. 测试完成后删除触发文件：
   ```bash
   rm ~/Library/Application\ Support/AIClockBridge/.check_update_now
   ```

## 关键实现细节

- Sparkle 不接受 `file://` feed URL，所以必须走 `http://localhost:8765/...`。
- app 自带的 HTTP 服务器在启动后会同时 serve `/updates/appcast.xml` 和 `/updates/*.app.zip`。
- `build-app.sh` 构建完成后会用 `codesign --force --deep --sign -` 对 `.app` 做 ad-hoc 签名；Sparkle 要求更新包有有效签名才能通过校验。
- `release.sh` 使用 Sparkle 官方 `sign_update` 工具生成 `sparkle:edSignature`，避免手写 OpenSSL 签名与 Sparkle 校验不兼容。

## 故障排查

- **检查更新报错无法连接**：确认 app 已启动（HTTP 服务器在运行），且 `Info.plist` 里的 `SUFeedURL` 是 `http://localhost:8765/updates/appcast.xml`。
- **“The update is improperly signed”**：通常是 `.app` 没有 ad-hoc 签名，或签名标识符与旧版本不一致。检查 `build-app.sh` 里的 `codesign` 步骤是否成功。
- **下载完无法替换应用**：ad-hoc 签名应用没有公证，首次运行/更新后可能需在“系统设置 → 隐私与安全性”放行。
- **菜单里没看到“检查更新”**：确保构建的是 release 版本，且 `Sparkle.framework` 已复制到 `.app/Contents/Frameworks`。
