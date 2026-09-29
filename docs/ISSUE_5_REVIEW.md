# #5 飞书授权流程深入复审

日期：2026-09-29。审查基线：本地 `422662f`（master，比 origin/master 多 1 个提交）。问题：[连接飞书报错](https://github.com/sinri/imbroglio/issues/5)，目前仍为 OPEN。

初次审查只做代码检查和隔离复现。用户随后确认修复，以下三项现已完成代码修复与自动化验证；原始发现保留用于追溯，处理结果见文末。

## 结论

现有修复对“凭证已保存，但部分权限缺失导致退出码 3”的识别符合官方 v1.0.96 实现，不能简单回退成非零退出一律失败。但授权与连接链路仍有 3 个可定位的遗漏，暂不建议以现有测试通过为依据关闭 #5。

## 资料与版本

按项目 `docs/VALIDATION.md` 记录的 v1.0.96 核对官方源码，通过 GitHub API 获取该 tag 的文件；tree SHA 为 `cb5a3d704379552dc61e37898e5f74798783190d`。未把 main 的行为直接当作固定版本契约。

- [官方 README：初始化、登录、验证是三个步骤](https://github.com/larksuite/cli/blob/v1.0.96/README.md)
- [登录和权限集合](https://github.com/larksuite/cli/blob/v1.0.96/cmd/auth/login.go)
- [登录完成事件与部分权限告警](https://github.com/larksuite/cli/blob/v1.0.96/cmd/auth/login_result.go)
- [身份状态命令](https://github.com/larksuite/cli/blob/v1.0.96/cmd/auth/status.go)
- [身份诊断结构](https://github.com/larksuite/cli/blob/v1.0.96/internal/identitydiag/diagnostics.go)
- [发送权限](https://github.com/larksuite/cli/blob/v1.0.96/shortcuts/im/im_messages_send.go)、[回复权限](https://github.com/larksuite/cli/blob/v1.0.96/shortcuts/im/im_messages_reply.go)、[快捷命令权限检查](https://github.com/larksuite/cli/blob/v1.0.96/shortcuts/common/runner.go)

## 1. P1：初次授权未申请用户发送权限，发送与回复缺少可用的授权路径

位置：`bin/im_adapter.dart:336`、`:568`、`:588`。

当前登录固定执行 `auth login --recommend --json`。官方 `login.go:280` 和 `:562` 明确从批量权限集合排除 `im:message.send_as_user`；只有显式 `--scope` 等后续授权才能补入。该权限没有被请求，因而也不会出现在本次登录的 `missing` 告警中。

项目发送和回复执行 `im +messages-send/+messages-reply --as user`。官方两个命令均将 `im:message.send_as_user` 和 `im:message` 声明为用户身份必需权限；`runner.go:1190` 的检查逐项计算缺失权限并返回 missing_scope，并非两个权限任选其一。

触发：新账号仅走当前默认登录，未另行授予发送权限。即使所有本次请求的权限都获批，发送所需权限仍缺失。项目没有补充指定 scope 的授权入口，普通发送也没有接入 `auth.url` 流程，因此不能依赖其自动完成补授权。这里确认的是授权集合与命令要求不匹配，未用真实账号发送消息。

建议：明确区分可读取与可发送状态，提供发送权限补授权入口；或按产品需要在初次登录显式追加该 scope。管理员拒绝或待审批时允许保留读取能力，但发送入口应给出可操作说明。避免无条件把全部权限缺失都视为不影响使用的告警。

验收：默认登录无发送权限时正确显示能力受限；补授权后可发送及回复；审批未通过时不反复初始化应用。

## 2. P2：登录返回的用户 ID 在连接前丢失，本人消息可能计入未读和通知

位置：`lib/src/services/workspace.dart:507`、`:517`；`lib/src/ui/settings.dart:1143`；`lib/src/services/workspace.dart:798`、`:1055`、`:1137`。

适配器已把 `authorization_complete.user_open_id` 转成 `userId`，但 `Workspace.authenticate` 仅从登录结果复制权限告警，返回的是另一次 status 的结果。飞书对话框随后调用 `w.connect(current!)`，未传 `userId`；connect 将默认空字符串写入账号。

`_isOwn` 依赖消息自带 isOwn 或账号 userId 与 senderId 相等。对没有 is_self 标志的正常历史/轮询消息，本人从飞书原客户端发出的消息因此可能增加本地未读，并触发 onIncoming。不能用本应用发送时标记的 isOwn 覆盖这一场景。

隔离复现：模拟登录明确返回 `userId: ou_review`，调用真实 `Workspace.authenticate` 后，返回结果不存在 userId，账号 userId 仍为空。UI 的 connect 调用进一步确认该值不会在连接时补回。

建议：保留登录 open_id，以 status 中对应用户身份核对，再传给 connect 并持久化。不要混用用户 open_id、union_id 和其他平台的 userId。

验收：首次授权及重新授权保存正确 open_id；本人在其他客户端发出的消息不增加未读、不发本人来信通知；其他人的消息照常处理。

## 3. P2：“连接验证”仅检查命令退出码，未验证用户身份是否可用

位置：`bin/im_adapter.dart:358`；`lib/src/services/workspace.dart:511`、`:554`。

当前只执行 `auth status --json`，没有 `--verify`，也没有检查 `identities.user.available/status/openId`。官方 status 命令会把身份诊断结果写到 JSON 后返回 nil：用户身份 missing/error、仅 bot 可用，都不等于命令执行失败。无 --verify 时也未向服务端校验 token。

隔离复现：真实 Adapter 子进程读取退出码 0、`identity: bot`、`identities.user.available: false` 的状态，正常返回；真实 Workspace.authenticate 同样接受该状态，没有抛出授权失败。

影响边界：后续会话查询可能发现 token 或权限异常，因此不能据此断言整个 UI 一定显示连接成功。但所谓“连接验证”本身已误通过，而且 connect 在会话查询前就保存 enabled=true，查询失败不回滚，可能遗留启用中的失败账号。已有测试使用 `status: ok` 占位，未覆盖官方身份结构。

建议：按用户身份检查状态和 open_id，并与本次登录身份一致性校验；使用 --verify 时读取结构化验证结果，不能只看退出码。区分 token 失效、网络验证失败和权限受限，并在最终连接失败时保留可重试但未连接的状态。

验收：user 缺失、仅 bot 可用、验证失败、身份不一致均不能当作有效用户连接；有效用户但缺少可选权限仍可进入受限状态。

## 已确认正确及未计为缺陷的事项

- 官方先保存 token、更新 profile，再检查 requested/granted 差异；缺少 scope 时输出 authorization_complete 和 missing_scope 告警，再返回退出码 3。现有严格判定与这一结构一致，未发现这部分修复需要撤销。
- JSON 登录授权链接来自 device_authorization.verification_uri_complete，现有解析选择正确。
- `config init --new` 默认 brand 为 feishu，不需要交互选择；没有把缺少显式 --brand 误报成初始化缺陷。
- 官方初始化确实先保存配置再执行探测，但探测忽略一般网络/超时噪声，只传播确定的凭证拒绝；不能把任意初始化非零退出当作成功。本次不将此路径列为已确认新缺陷。
- `--recommend` 在该版本接近全部业务域权限集合，并非只覆盖本项目功能。后续宜按功能定义权限需求；这是设计建议，不单独计为故障。

## 验证记录和限制

- `flutter test --no-pub test/cli_failure_test.dart test/account_dialog_test.dart test/sync_test.dart test/adapter_test.dart test/diagnostics_test.dart test/rpc_test.dart`：80 项通过。
- 临时隔离复现 `/private/tmp/review5_probe_test.dart`：2 项通过。断言的是当前错误行为确实存在，不是修复回归测试。
- 测试日志：`/private/tmp/imbroglio-review5-tests.log`、`/private/tmp/imbroglio-review5-probes.log`。
- 未进行真实飞书账号浏览器授权、权限审批、发消息或线上 token 验证。首次登录、拒绝可选权限、发送权限审批及重新授权仍需真实账号验收。
- 本轮仅新增审查文档；无业务代码修改，未创建新 Issue，也未关闭 #5。

## 修复结果（用户确认后）

1. 登录显式追加 `im:message.send_as_user im:message`；连接验证根据已授予 scope 保存 `canSend`。权限不足仍可连接读取，聊天发送按钮禁用、服务层也在写入发送记录前拒绝；设置提供“补充发送授权”，复用已有配置，不重新创建应用。既有账号需要通过设置中的“授权”重新验证并保存能力状态。
2. 验证后的 open_id 通过对话框传给 connect 并持久化。回归测试覆盖本人在其他客户端发送的轮询消息不增加未读、不触发来信通知。
3. status 增加 `--verify`；检查用户身份 available、verified、状态和非空 open_id，并与本次登录一致。会话查询成功后才保存 enabled=true，失败保持未连接。

验证：完整 `flutter test --no-pub` 166 项通过，`flutter analyze --no-pub` 无问题；独立适配器 AOT 编译通过。测试包含有效且缺少权限、验证失败、身份不一致、重新授权、能力持久化和失败账号状态。真实账号授权、权限审批与实际发送仍待验收；未提交代码或关闭 Issue。

macOS Debug 应用构建及打包通过，产物为 `dist/imbroglio-macos-arm64-debug.zip`；已核对包内应用适配器与本轮编译产物 SHA-256 一致。使用新包重新打开应用后，既有飞书账号可在设置中点击“授权”完成验证和权限更新。

## 后续交互优化：先查询，再决定是否授权

根据用户进一步要求，连接现先检查当前应用与用户授权。可用的基础读取权限允许直接连接，发送及文档能力供用户选择；只有需要新增权限或明确选择重新授权时才运行登录。补授权使用已有权限与所选权限的并集，取代默认 --recommend。查询失败不会自动转入登录流程。基础 scope 列表与 CLI v1.0.96 的会话/消息快捷命令预检查保持一致。

新增预检查及界面测试后全套 181 项通过；静态检查无问题，真实账号的应用权限查询、浏览器授权和发送仍待实际验收。最新行为以 `ISSUE_5.md` 的“授权前检查与按需授权”一节为准。
