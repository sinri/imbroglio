import 'package:flutter/material.dart';
import '../core/conversation_blacklist.dart';
import '../services/workspace.dart';

class ConversationBlacklistDialog extends StatefulWidget {
  final Workspace workspace;
  const ConversationBlacklistDialog({super.key, required this.workspace});

  @override
  State<ConversationBlacklistDialog> createState() => _BlacklistDialogState();
}

class _BlacklistDialogState extends State<ConversationBlacklistDialog> {
  bool saving = false;
  String? error;

  Future<void> save(List<ConversationBlacklistRule> rules) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.workspace.saveConversationBlacklist(rules);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> edit([int? index]) async {
    final rules = widget.workspace.conversationBlacklist;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RuleEditor(
        workspace: widget.workspace,
        initial: index == null ? null : rules[index],
        onSave: (rule) async {
          final updated = rules.toList();
          if (index == null) {
            updated.add(rule);
          } else {
            updated[index] = rule;
          }
          await save(updated);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.workspace;
    final rules = w.conversationBlacklist;
    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: const Text('会话黑名单'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('命中的会话仍显示在列表中并可搜索，停止自动拉取；点击打开会临时拉取消息，已有消息保留。'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: Text('已有规则（${rules.length}）')),
                    FilledButton.icon(
                      onPressed: saving ? null : () => edit(),
                      icon: const Icon(Icons.add),
                      label: const Text('新增规则'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (rules.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('暂无规则。点击「新增规则」设置要排除的会话。'),
                  ),
                for (var i = 0; i < rules.length; i++)
                  Card(
                    child: ListTile(
                      title: Text(rules[i].pattern),
                      subtitle: Text(
                        '${rules[i].regex ? '正则表达式' : '通配符'} · ${rules[i].accountId.isEmpty ? '全部账号' : w.accounts.where((a) => a.id == rules[i].accountId).firstOrNull?.label ?? '已删除账号'} · 命中 ${w.conversations.where(rules[i].matches).length} 个会话',
                      ),
                      onTap: saving ? null : () => edit(i),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '编辑规则',
                            onPressed: saving ? null : () => edit(i),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '删除规则',
                            onPressed: saving
                                ? null
                                : () async {
                                    try {
                                      await save(rules.toList()..removeAt(i));
                                    } catch (e) {
                                      if (mounted) setState(() => error = '$e');
                                    }
                                  },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 12),
                const Text('规则保存或删除后立即生效，任意一条命中即排除。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}

class _RuleEditor extends StatefulWidget {
  final Workspace workspace;
  final ConversationBlacklistRule? initial;
  final Future<void> Function(ConversationBlacklistRule) onSave;
  const _RuleEditor({
    required this.workspace,
    required this.initial,
    required this.onSave,
  });

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final pattern = TextEditingController(
    text: widget.initial?.pattern ?? '',
  );
  final patternFocus = FocusNode();
  late String accountId = widget.initial?.accountId ?? '';
  late bool regex = widget.initial?.regex ?? false;
  bool saving = false;
  String? error;

  ConversationBlacklistRule? get candidate {
    try {
      return ConversationBlacklistRule(
        pattern: pattern.text,
        accountId: accountId,
        regex: regex,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  void dispose() {
    patternFocus.dispose();
    pattern.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rule = candidate;
    final matches = rule == null
        ? []
        : widget.workspace.conversations.where(rule.matches).toList();
    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: Text(widget.initial == null ? '新增黑名单规则' : '编辑黑名单规则'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('规则区分大小写。保存后立即生效。'),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: accountId,
                  decoration: const InputDecoration(labelText: '生效账号'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部账号')),
                    if (accountId.isNotEmpty &&
                        !widget.workspace.accounts.any(
                          (a) => a.id == accountId,
                        ))
                      DropdownMenuItem(
                        value: accountId,
                        child: const Text('已删除账号'),
                      ),
                    for (final a in widget.workspace.accounts.where(
                      (a) => !a.signedOut || a.id == accountId,
                    ))
                      DropdownMenuItem(value: a.id, child: Text(a.label)),
                  ],
                  onChanged: saving
                      ? null
                      : (value) {
                          setState(() => accountId = value!);
                          patternFocus.requestFocus();
                        },
                ),
                SwitchListTile(
                  title: const Text('使用正则表达式'),
                  subtitle: Text(
                    regex
                        ? '匹配名称中的任意部分；可用 ^ 和 \$ 限定完整名称'
                        : '* 匹配任意字符，? 匹配单个字符；匹配完整名称',
                  ),
                  value: regex,
                  onChanged: saving ? null : (v) => setState(() => regex = v),
                ),
                TextField(
                  key: const ValueKey('conversation-blacklist-pattern'),
                  controller: pattern,
                  focusNode: patternFocus,
                  autofocus: true,
                  enabled: !saving,
                  decoration: InputDecoration(
                    labelText: '会话名称规则',
                    hintText: '请输入规则',
                    helperText: regex ? '例如：^通知.*' : '例如：通知*',
                    errorText: pattern.text.isNotEmpty && rule == null
                        ? '请输入有效的规则'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Text('当前已加载会话命中 ${matches.length} 个'),
                const SizedBox(height: 8),
                if (matches.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final c in matches)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                '${widget.workspace.account(c.accountId).label} · ${c.title}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving || rule == null
                ? null
                : () async {
                    setState(() {
                      saving = true;
                      error = null;
                    });
                    try {
                      await widget.onSave(rule);
                      if (mounted) {
                        setState(() => saving = false);
                        if (context.mounted) Navigator.pop(context);
                      }
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          saving = false;
                          error = '$e';
                        });
                      }
                    }
                  },
            child: Text(saving ? '保存中' : '保存规则'),
          ),
        ],
      ),
    );
  }
}
