# TODO

## 股票页遗留项（主体已于 2026-07-13 实现）
- 备用数据源故障切换：新浪 `hq.sinajs.cn`（需 Referer 头）作腾讯接口的 fallback，参考 [Ashare](https://github.com/mpquant/Ashare) 双核心设计
- 有线（无 WiFi）模式下的中文名称条：名称位图走 HTTP，纯 USB 时只显示代码，需串口分帧方案
- 设备网页配置自选股（目前只有 Mac/Win 菜单）

## USB 有线直连（本轮做了 Mac + 固件，遗留项）
- Windows 桥接串口支持（System.IO.Ports，扫 COM 口 + 同款 #HELLO/#STATUS/#NET 协议）
- 有线模式下的控制通道：镜像/菜单的亮度、屏幕切换走 `#CMD`（固件已支持 display/brightness，桥接端未接）
- 有线模式下音乐页数据（封面/文字条是二进制位图，需分帧或 base64，暂不支持，AUTO 不会自动切音乐页）
- 镜像弹窗在设备无 WiFi 时拉不到精灵图（GET /sprite/*/raw 走 HTTP），显示占位
