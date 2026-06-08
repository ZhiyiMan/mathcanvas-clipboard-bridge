# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-06-08

### Added

- iPad 手写主界面（PencilKit 全屏画布）
- 清空与发送按钮（无边记风格悬浮按钮）
- 发送图片到 Mac 本地服务（HTTP POST）
- App 内服务地址设置（便于分享和朋友自助配置）
- Mac 端接收服务 `mac_server/clipboard_server.py`
- 一键启动脚本 `mac_server/start_server.command`
- 项目文档 `README.md`
- 开源许可 `LICENSE (MIT)`

### Improved

- 画布支持缩放与平移，接近无边记使用体验
- 导出图片逻辑按当前可见区域进行渲染
- 工具选择器与橡皮擦同步稳定性优化
