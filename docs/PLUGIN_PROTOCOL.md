# Imbroglio 插件协议 v1

主应用通过绝对路径启动插件。stdin/stdout 每行一个 UTF-8 JSON-RPC 2.0 对象；stderr 是诊断流，不作为业务响应。首版不提供 OS 沙箱，安装可执行 IM 插件意味着信任当前用户权限下的代码。

请求示例：

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":1,"platform":"feishu","binary":"/absolute/managed/lark-cli","directory":"/absolute/account","accountId":"local-uuid","profile":"exact-profile"}}
```

成功响应 `{"jsonrpc":"2.0","id":1,"result":{...}}`；错误响应 `{"jsonrpc":"2.0","id":1,"error":{"code":"authorization","message":"缺少授权","retryAfter":60}}`。同一行不可输出日志或启动标语。单次响应上限 8 MiB。

## 方法

| 方法 | 输入 | 输出 |
| --- | --- | --- |
| initialize | 上述初始化参数 | protocol=1、capabilities |
| health / capabilities | 无 | 运行状态 / 能力表 |
| auth.configure | 可选 appId、appSecret（仅传入 stdin） | configured |
| auth.login | 无 | completed；过程中通知 auth.url |
| auth.status / auth.logout | 无 | 状态 / 空对象 |
| conversations | 可选 cursor | items: Conversation[]、cursor |
| messages | conversation、可选 before/since（毫秒）/cursor | items: Message[]、cursor、hasMore |
| send | conversation、text、reply、attachment、image、markdown、idempotencyKey、approved | result、messageId |
| contacts / conversation.open | query / contact | items / Conversation |
| contacts.resolve | ids（最多 20 个平台用户 ID）、可选 conversation、openIds（查询 ID → 钉钉 openDingTalkId） | items: {id, name, avatar, avatarResourceId?}[]；头像资源由宿主通过 attachment.download 下载到账号缓存，缺权限时降级为消息自带身份 |
| messages.search | query | items、coverage |
| resources.search / resources.read | query / id | items: ResourceRef[] / text |
| attachment.download | message、resourceId | path（必须位于账号 downloads 子目录） |
| tool.execute | tool、arguments、idempotencyKey、approved | 平台结果 |
| subscribe / unsubscribe | conversation / conversationId | started / 空对象 |
| cancel | id（通知） | 取消对应子进程 |
| shutdown | 无 | closed=true，关闭自有消费者并退出 |

通知包括 `message`、`auth.url`、`sync.ready`、`sync.gap`。消息去重使用 `(accountId, message.id)`，不能使用 event ID。所有 ID 为 opaque string；所有时间为 Unix 毫秒。公共类型以 `lib/src/core/models.dart` 为准。

`approved` 由宿主在用户点击发送或确认后设置，模型不能自行指定它。宿主决定资源范围、单次确认和写操作审计；CLI 自身的确认错误不静默追加 `--yes`。插件不能更改响应中的 accountId。

## 本地 ZIP 插件包

ZIP 根目录必须包含 `manifest.json`。其他每个文件都必须列入 files 的 SHA-256 映射；不接受绝对路径、路径穿越、符号链接或重复目标路径。安装前展示包 SHA-256 和权限。校验防止内容不一致，并不证明未知作者可信。

Agent 插件不包含可执行代码：

```json
{
  "id": "example.summary",
  "name": "业务摘要",
  "version": "1.0.0",
  "protocol": 1,
  "kind": "agent",
  "prompt": "依据来源总结业务进展。",
  "tools": ["search", "read_source", "conversations", "history"],
  "workflow": ["retrieve", "analyze", "confirm_writes", "report"],
  "files": {}
}
```

工作流使用宿主固定的检索、分析、确认、报告循环；不支持嵌入 JS 或执行任意 shell。Agent 可用工具在 `agentTools` 中声明，未知工具不可调用。

IM 插件使用 `kind: "im"`，增加 `entrypoints`，例如 `{"darwin-arm64":"bin/connector"}`，以及 `permissions` 列表。平台键为 darwin/windows/linux 与 amd64/arm64 的组合。所有可执行文件在 files 中校验。更新以相同 ID 导入新版本插件包；官方 CLI 通过插件中心单独更新。

第三方 IM 插件自行实现初始化协议，不依赖系统 CLI。插件启停与账号同步状态独立；停用后需在账号设置中恢复同步。
