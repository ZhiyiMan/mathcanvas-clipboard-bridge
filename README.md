# MathCanvas

在 iPad 上用 Apple Pencil 手写数学步骤，点击发送后自动传到 Mac 本地服务，并写入系统剪贴板，直接 `Cmd+V` 粘贴使用。

## 功能

- iPad 全屏手写（PencilKit）
- 无边记风格画布（可缩放/平移）
- 一键发送图片到 Mac（局域网 HTTP）
- Mac 自动写剪贴板，方便粘贴到 AI的聊天窗口
- App 内可修改服务地址，便于分享给朋友

## 快速开始（3 分钟）

### 1) 启动 Mac 服务

在项目目录运行：

```bash
python3 mac_server/clipboard_server.py
```

或双击：

`mac_server/start_server.command`

服务启动后会打印推荐地址，例如：

`http://192.168.2.101:8765/upload`

### 2) iPad 端配置

打开 App 后，点右下角 **服务** 按钮：

- 填写 Mac 端打印的地址（通常只需要改 IP）
- 端口保持 `8765`
- 路径保持 `/upload`

示例格式：

`http://192.168.x.x:8765/upload`

### 3) 正常使用

1. iPad 和 Mac 连接同一 Wi-Fi
2. iPad 手写并点 **发送**
3. Mac 收到后自动放入剪贴板
4. 在任意输入框按 `Cmd+V` 粘贴图片

## 项目结构

```text
MathCanvas/
├─ MathCanvas/                    # iPad App (SwiftUI + PencilKit)
├─ mac_server/                    # Mac 本地接收服务
│  ├─ clipboard_server.py
│  └─ start_server.command
├─ README.md
├─ CHANGELOG.md
└─ LICENSE
```

## 截图 / 演示

你可以在这里放 1 张主界面截图和 1 个发送流程 GIF：

- `docs/screenshot-ipad.png`
- `docs/demo-send.gif`

## 常见问题

- **Address already in use**
  - 说明端口已被占用；先停掉旧进程再启动。
- **iPad 发送失败**
  - 检查服务地址是否正确；
  - 确认 iPad 首次弹出的“本地网络权限”已允许；
  - 确认 Mac 防火墙未阻止 Python。
- **能收到文件但没进剪贴板**
  - 先看服务终端日志；
  - 可尝试重启服务；
  - 确认 macOS 已允许终端相关自动化权限（如有弹窗）。

## 许可证

本项目使用 [MIT License](LICENSE)。