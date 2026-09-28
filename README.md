# Imbroglio

Flutter 桌面 IM 与 Agent 工作台，面向 Windows、macOS 和 Linux。通过独立进程连接官方钉钉 `dws` 与飞书 `lark-cli`，聚合消息、资料检索和需确认的 Agent 业务操作。

本机已生成 macOS Apple Silicon 包：`dist/imbroglio-macos-arm64-release.zip`。解压后打开应用，在「插件」安装官方 CLI，再连接测试账号。各平台产物按 CPU 架构分别构建。

## 开发运行

使用 Flutter 3.41.5 / Dart 3.11.3。本项目管理的 CLI 不要求终端预装 Node、Go、dws 或 lark-cli。

```sh
flutter pub get
dart run tool/build_adapter.dart
flutter run -d macos
```

其他系统将设备改为 `windows` 或 `linux`。必须先构建独立适配器。运行后在「插件」安装官方 CLI，再连接账号；在「设置」填写兼容 Chat Completions 的模型地址、模型名和密钥。

Linux 构建依赖：

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libx11-dev libxi-dev libayatana-appindicator3-dev libnotify-dev libsecret-1-dev
```

Linux 密钥存储需要可用的 Secret Service。GNOME 托盘需要 AppIndicator 支持；没有托盘时关闭窗口正常退出，不隐藏成无法恢复的后台窗口。

## 构建与测试

```sh
flutter analyze --no-pub
flutter test --no-pub
python3 tool/package.py
```

`tool/package.py` 在本机平台编译应用和适配器并将其放入 `dist/`。Windows 使用 `python`。macOS 最低 12，Windows 面向 10/11 x64，Linux 基线为 Ubuntu 22.04/24.04。CI 在对应系统运行分析、测试和打包，不能用本机 macOS 编译结果代替 Windows/Linux 验证。

本地 macOS 包为 ad-hoc 签名。正式公证、Developer ID 或 Windows 代码签名需要发布者证书，当前工作流不发布到商店。

## 已实现的主要路径

- 官方 CLI 下载、SHA-256 校验、能力探测、独立版本目录、启停和上一版回滚。
- 多账号配置、浏览器授权入口、独立配置/缓存/工作目录；不自动导入系统配置。
- 会话与消息展示、历史加载、文本/Markdown、引用回复、附件发送与下载、联系人查询、关注会话、托盘和桌面通知。
- 钉钉个人事件订阅，飞书个人消息定时同步；本地去重、同步状态、限流退避、发送记录和未知结果保护。
- SQLite/Drift 存储、中文全文检索、在线消息/文档搜索、按需读文档和来源引用。
- 流式模型对话、工具调用、写入预览、单次参数绑定确认、取消、执行步数上限、会话与审计记录。
- 声明式 Agent 插件和可独立安装的 JSON-RPC IM 插件包。参见 [插件协议](docs/PLUGIN_PROTOCOL.md)。

## 边界

- 平台开放能力与组织授权决定实际可用范围。飞书机器人事件不等同个人全部消息流；不能保证完全替代原客户端全部功能。
- 配置与缓存隔离不代表系统凭证完全隔离。同一账号的登录/退出可能影响系统 CLI；应用提示此边界，不自动迁移或重置凭证。
- SQLite 消息缓存未启用整体加密；模型密钥保存在系统安全存储。选定资料会发送到用户配置的模型服务。
- 第三方可执行插件具备当前用户进程权限，独立进程不是 OS 安全沙箱。首版采用手动 ZIP 导入，没有公共插件市场。
- CLI 适配器基于官方命令帮助和结构化输出契约。真实租户可能返回不同版本字段或缺少 scope；契约不匹配会显示错误，不伪造成功。真实账号端到端验证需要专用测试账号。
- 登录/授权由用户在应用内主动发起；开发测试不使用现有私人聊天或登录态。

参见 [架构与验收](docs/ARCHITECTURE.md) 和 [验证记录](docs/VALIDATION.md)。
