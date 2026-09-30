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
| conversations.active（内置 IM） | start/end（Unix 毫秒）、可选 cursor；分页保持相同时间窗口 | items: Conversation[]（活跃摘要）、cursor、complete（布尔，仅分页耗尽为 true） |
| conversations | 可选 cursor | items: Conversation[]、cursor |
| identity.self（钉钉） | 无 | userId、ids：经当前用户资料及精确 userId 匹配确认的消息身份别名 |
| notifications.settings | ids（最多 10 个会话 ID） | items: {id, muted: bool}[]；缺项表示未知，钉钉返回完整账号快照供缓存 |
| messages | conversation、可选 before/since/notBefore（毫秒）/cursor；notBefore 是自动初始化历史的下限，不改变倒序分页方向 | items: Message[]、cursor、hasMore |
| send | conversation、text、reply、attachment、image、markdown、idempotencyKey、approved | result、messageId |
| contacts / conversation.open | query / contact | items / Conversation |
| contacts.resolve | ids（最多 20 个平台用户 ID）、可选 conversation、openIds（查询 ID → 钉钉 openDingTalkId） | items: {id, name, avatar, avatarResourceId?}[]；头像资源由宿主通过 attachment.download 下载到账号缓存，缺权限时降级为消息自带身份 |
| messages.search | query | items、coverage |
| resources.search / resources.read | query / id | items: ResourceRef[] / text |
| attachment.download | message、resourceId | path（必须位于账号 downloads 子目录） |
| tool.execute | tool、arguments、idempotencyKey、approved | 平台结果 |
| subscribe / unsubscribe（兼容旧协议） | conversation / conversationId | 内置适配器拒绝 subscribe；unsubscribe 保留清理能力 |
| cancel | id（通知） | 取消对应子进程 |
| shutdown | 无 | closed=true，关闭自有消费者并退出 |

通知包括 `message`、`auth.url`、`sync.ready`、`sync.gap`。消息去重使用 `(accountId, message.id)`，不能使用 event ID。所有 ID 为 opaque string；所有时间为 Unix 毫秒。公共类型以 `lib/src/core/models.dart` 为准。

`approved` 由宿主在用户点击发送或确认后设置，模型不能自行指定它。宿主决定资源范围、单次确认和写操作审计；CLI 自身的确认错误不静默追加 `--yes`。插件不能更改响应中的 accountId。

## 本地 ZIP 插件包

ZIP 根目录必须包含 `manifest.json`。其他每个文件都必须列入 files 的 SHA-256 映射；不接受绝对路径、路径穿越、符号链接或重复目标路径。安装前展示包 SHA-256 和权限。校验防止内容不一致，并不证明未知作者可信。

基础 Agent 插件可以只声明提示词和工具：

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

`workflow` 当前为描述性字段，不参与执行；运行使用宿主的模型与工具循环。业务工具在 `agentTools` 中声明，未知工具不可调用。本地脚本通过下述显式声明和用户开关开放，模型不能自行提供 shell 命令。

IM 插件使用 `kind: "im"`，增加 `entrypoints`，例如 `{"darwin-arm64":"bin/connector"}`，以及 `permissions` 列表。平台键为 darwin/windows/linux 与 amd64/arm64 的组合。所有可执行文件在 files 中校验。更新以相同 ID 导入新版本插件包；官方 CLI 通过插件中心单独更新。

第三方 IM 插件自行实现初始化协议，不依赖系统 CLI。插件启停与账号同步状态独立；停用后需在账号设置中恢复同步。

## 诊断事件

`diagnostic` 通知携带 `operation`、`detail`，可附 `conversationId`、`exitCode`。主应用再次脱敏后在 SQLite 的 diagnostics bucket 保存最近 200 条，GUI 底部“CLI 诊断记录”可查看和复制。当前主应用只轮询，不创建订阅；忽略旧订阅的就绪及断开通知，普通 `sync.gap` 通知仍可触发补拉。

平台明确拒绝保密群消息时返回 `confidential_group`，主应用持久保存该会话的停拉策略，不再自动或手动拉取历史/增量，也不再建立订阅。首次发现依赖平台错误，未获得群保密属性前无法提前判断。


## Agent / skill 目录（本地扩展）

在「插件」点击「导入 Agent / skill 目录」，选择包含一组定义的父目录，也可选择单个定义目录。宿主递归查找 `manifest.json`，每份定义占一个独立目录，定义目录之间不得嵌套。支持布局：

```text
my-agents/
  agents/helper/manifest.json
  skills/text-stats/manifest.json
  skills/text-stats/SKILL.md
  skills/text-stats/scripts/count.py
```

可直接导入仓库的 `examples/agent-bundle` 体验。示例脚本要求本机可找到 `python3`；宿主不会自动安装解释器。

Agent 保留原有必填字段，并可声明 `skills: ["example.text-stats"]`。skill 使用 `kind: "skill"` 和相同的 ID、名称、版本、协议字段。skill 的 `prompt` 可省略，此时读取同目录的 `SKILL.md` 全文作为指令，`tools` 默认空列表；不解析 Markdown front matter。skill 必须有 manifest，暂不支持仅凭裸 `SKILL.md` 发现。skill 不能继续引用其他 skill。

运行时读取最新安装定义，把 Agent 和引用 skill 的指令合并、业务工具白名单取并集。引用的 skill 缺失或停用时报告错误，不静默忽略。skill 在插件页单独启停，不能作为独立 Agent 发起对话。Agent 与 skill 都可添加：

```json
"scripts": [
  {
    "id": "count",
    "description": "统计文本，输入 JSON 为 {\"text\":\"内容\"}",
    "path": "scripts/count.py",
    "interpreter": "python3",
    "timeoutSeconds": 30
  }
]
```

`path` 必须指向定义目录内的文件；脚本 ID 在定义内唯一。`interpreter` 是本机解释器名称或绝对路径，不接受模型传入解释器参数。执行方式为 `interpreter script-path`，不经过 shell 拼接。模型通过 `run_script` 选择 `定义ID/脚本ID`，提供 JSON 字符串 `input`，宿主通过 stdin 传入；工作目录为安装副本目录。脚本通过 stdout/stderr 返回结果，宿主把退出码、输出、取消与超时状态交给模型。

### 开关与执行边界

- 「允许本地脚本执行」为工作区设置，默认关闭，导入、更新和定义文件均不会自动开启它。关闭时不向模型开放脚本工具，执行入口也再次检查开关。
- 开启后，每次执行仍显示定义、解释器、脚本路径和输入，用户确认后执行；取消或拒绝不启动脚本。关闭开关会拒绝正在等待的脚本确认，并终止当前直接启动的脚本进程。
- 输入最多 32768 字符；stdout/stderr 合计最多 128 KiB，超过后终止进程。超时默认 60 秒，定义可设 1–300 秒。Agent 的停止操作同样终止直接启动的脚本进程。
- 脚本以当前用户权限执行并继承进程环境，**不是 OS 沙箱**，可读写文件、访问网络。账号范围约束仅适用于宿主业务工具，不约束脚本。不要在脚本中启动脱离父进程的后台任务；当前不保证终止脚本派生的全部子孙进程。
- 脚本执行记录包含定义、脚本 ID 和运行状态，不把 stdin/stdout 全文写入审计；工具结果仍会进入 Agent 对话，并发送给配置的模型服务。

### 导入与更新

导入会复制文件并保存 SHA-256，之后修改源目录不影响安装版本。更改后重新导入，以相同 ID 更新；不能覆盖内置 Agent 或 IM 插件。停用与卸载沿用插件页现有操作。

整个导入目录最多 50 MiB / 2000 个文件，不接受符号链接，校验全部定义和 skill 引用后在事务中注册。脚本每次执行前验证路径和入口文件 SHA-256，入口文件被修改时要求重新导入。校验用于发现入口文件变化，不构成对本机其他进程或脚本依赖的安全隔离。更新不删除旧版本目录；卸载该定义时一起清理。

## MCP 工具服务器

「插件中心 → MCP 服务器 → 添加服务器」支持配置独立的本地 `stdio` 或远程 `Streamable HTTP` 服务器。新增、编辑保存后默认停用；用户主动启用后，才会在点击「测试连接与查看工具」或运行 Agent 时启动/连接。测试仅握手和发现工具，不调用业务工具。修改、停用、删除会关闭对应的活动连接，后续请求也检查配置版本。

本地配置示例（替换脚本为绝对路径）：

```json
{
  "id": "local-echo",
  "name": "本地回声示例",
  "transport": "stdio",
  "command": "python3",
  "args": ["/absolute/path/imbroglio/examples/mcp/echo_server.py"],
  "env": {}
}
```

本地服务需要预先安装运行时/可执行文件，支持可选 `cwd`。启动不经过 shell 拼接，命令参数逐项传递；环境继承当前进程，并叠加 `env`。MCP 本地进程由服务器自身的启用开关控制，与 Agent 定义中的「允许本地脚本执行」开关独立；拥有当前用户权限，不是 OS 沙箱。停用时终止直接启动的进程，不保证清理全部派生进程。

远程配置示例：

```json
{
  "id": "remote-tools",
  "name": "远程工具",
  "transport": "http",
  "url": "https://example.com/mcp",
  "headers": {"Authorization": "Bearer YOUR_TOKEN"}
}
```

远程要求 HTTPS，仅 `localhost`、`127.0.0.1`、`::1` 可用 HTTP。不跟随 HTTP 重定向。`env` 和 `headers` 单独保存在系统安全存储，不写入普通配置数据库；其他字段不加密，请勿把凭据放在 `args`、URL 或名称中。编辑时会显示既有配置，包括这些凭据。

### Agent 使用范围与确认

默认向 Agent 开放当前工作区所有已启用服务器的工具。Agent 或 skill 可声明 `"mcpServers": ["local-echo"]`；只要参与本轮运行的任一定义包含此字段，就按这些显式列表的并集筛选，未启用服务器仍不可用。全部显式列表为空时不连接任何 MCP 服务器。字段只引用已有配置，导入定义不会创建或启用服务器。

宿主将工具的 JSON Schema 传给模型，使用服务器 ID 和原始工具名生成稳定、不冲突的模型工具名。界面确认展示原始服务器名、工具名及参数；**所有 MCP 工具调用均需用户确认**，不依赖服务器的 `readOnlyHint` 等提示自动跳过确认。确认后再次检查启用状态及配置版本，拒绝或停用后不发送 `tools/call`。MCP 工具不受 IM 账号范围约束。

工具的文本、文本资源和结构化结果会进入对话并发送给配置的模型；图片、音频和二进制资源目前只返回省略提示。审计记录服务器 ID、工具名与执行状态，不记录完整参数、输出和认证信息。外部工具的描述和返回值均作为不可信资料，不作为系统指令。

### 协议与边界

实现参考 [MCP 传输协议](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)及[工具协议](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。支持 `2025-11-25`、`2025-06-18`、`2025-03-26` 版本协商、`initialize` / `notifications/initialized`、分页 `tools/list`、`tools/call`、ping 与 JSON-RPC 错误。HTTP 支持 JSON 和 SSE POST 响应、会话 ID、版本请求头及会话 DELETE；不支持旧式独立 SSE endpoint、OAuth 登录、服务端 sampling/elicitation、独立 resources/prompts 浏览和任务扩展。

每轮 Agent 运行重新连接并发现工具，结束后关闭；当前不实时刷新 `tools/list_changed`，下一轮重新发现。请求超时 45 秒，每条协议消息/HTTP 响应最多 2 MiB，每轮最多 8 个服务器、共 128 个工具；工具参数最多 65536 字符，给模型的结果最多 128 Ki 字符，超过会标明截断。连接失败会显示错误，不静默伪造可用工具。

取消或超时会尽力发送 `notifications/cancelled` 并关闭连接，本地进程先关闭 stdin，随后按需终止。远程取消不保证撤销已发生的操作。断线、HTTP 会话过期（404）及 SSE 流中断时不自动重放工具调用；需核对结果后重新发起一轮运行，建立新会话。当前不恢复 SSE event ID。

## 内置 Agent / skill 编辑器

在插件中心点击「新建 Agent」或「新建 Skill」，即可直接创建定义，无需准备 JSON 或导入目录。已有卡片的「更多操作 → 编辑定义」可修改内置、导入和本地创建的 Agent / skill。

编辑器提供：

- 基本信息：ID、名称、版本。编辑已有定义时固定 ID 和类型；新建时 ID 必须唯一，名称可重复。版本由用户填写，不自动递增。
- 指令：Markdown 文本，作为 Agent 的提示词或 skill 的指导内容。
- 业务工具：勾选宿主工具；已有未知工具会标记不可用，保留到用户主动移除。
- 引用技能：Agent 可选择已安装 skill；skill 本身不引用其他 skill。
- MCP 范围：默认不限定；关闭「不限定 MCP 服务器」后可选择服务器，也可保存空列表。运行时仍按 Agent 和引用技能的显式列表并集合并；未启用服务器不会连接。
- 本地脚本：添加、移除或编辑脚本 ID、文件相对路径、解释器、超时、说明及 UTF-8 代码。单个脚本编辑上限 1 MiB，共用文件路径的脚本必须具有相同代码。

保存只更新定义和文件，不执行脚本，不开启脚本权限，也不启用 MCP 服务器。新定义默认启用；修改已有定义保留其启用/停用状态及内置标识。内置定义仍不可卸载，也不能被目录导入覆盖，但可在编辑器中修改。

保存会生成新的安装副本及文件摘要，保留注册的其他附件/依赖文件，并同步写入 `manifest.json` 和 skill 的 `SKILL.md`。修改导入定义不影响原始导入目录。移除脚本声明后不再向模型开放该脚本；已安装的辅助文件仍保留，卸载定义时统一清理。保存后的定义在下一轮运行生效；已等待确认的旧脚本不会沿用旧目录继续执行。

保存前检查技能引用、脚本路径和当前定义状态。重复 ID、编辑期间发生更新或已注册文件在外部被修改时，拒绝保存并保留编辑器草稿，避免覆盖未查看的变化。可以关闭后重新打开最新定义，或重新导入外部文件再编辑。取消时不写入任何定义或脚本文件；有未保存修改时提示是否放弃。
