# 飞书插件权限清单

核对日期：2026-09-29；托管 CLI：v1.0.96。以下均为用户身份权限。
清单对应当前适配器实际调用，通过该版本 CLI 帮助和 `--dry-run --as user` 的权限预检核对；dry-run 不执行发送或创建操作。

| 功能 | CLI 调用 | 所需权限 |
| --- | --- | --- |
| 会话列表 | `im +chat-list` | `im:chat:read` |
| 群聊、单聊消息 | `im +chat-messages-list` | `im:message.group_msg:get_as_user`、`im:message.p2p_msg:get_as_user`、`im:message.reactions:read`（CLI 预检） |
| 图片、附件下载 | `im +messages-resources-download` | `im:message:readonly` |
| 联系人搜索、发送者资料 | `contact +search-user`（含 `--user-ids`） | `contact:user:search` |
| 消息搜索 | `im +messages-search` | `search:message` |
| 发送、回复消息 | `im +messages-send`、`im +messages-reply` | `im:message.send_as_user`、`im:message` |
| 文档搜索、读取 | `drive +search`、`docs +fetch` | `search:docs:read`、`docx:document:readonly` |
| Agent 创建文档 | `docs +create` | `docx:document:create` |
| Agent 创建待办 | `task +create` | `task:task:write` |

代码中的 `feishuReadScopes` 包含消息、附件、联系人和消息搜索。发送、文档读取、Agent 写入分别单独选择；“一次性授权全部功能”合并上述权限，并保留已有授权。实际写入仍受应用内操作确认控制。

## 已有账号补授权

1. 在飞书开放平台应用的“权限管理”中开通需要的用户身份权限；按平台提示完成发布或审批。
2. 在应用内重新授权，可复制全部功能权限清单并一次性授权全部功能。
3. 完成用户授权后验证登录态，并实际查询联系人。应用开通权限与用户授权是两步，缺少其中任一步都可能失败。

本次对已有账号的检查发现以下五项同时缺少应用开通和用户授权：

```text
contact:user:search
search:message
im:message:readonly
docx:document:create
task:task:write
```

保留现有 `offline_access` 等登录基础权限。不要用 `--domain all` 替代此清单，以免请求与插件无关的业务权限。跨租户用户或机器人可能受可见范围及接口类型限制；授权成功不代表任意用户的所有资料都可读取。
