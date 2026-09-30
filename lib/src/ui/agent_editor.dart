import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../services/agent.dart';
import '../services/agent_extensions.dart';

/// Draft-only editor. Files and records are written only by the Save action.
class AgentDefinitionEditor extends StatefulWidget {
  final AgentExtensions extensions;
  final Json? original;
  final String kind;
  final List<Json> skills, servers;
  final Map<String, String> sources;
  const AgentDefinitionEditor({
    super.key,
    required this.extensions,
    required this.kind,
    required this.skills,
    required this.servers,
    this.original,
    this.sources = const {},
  });
  @override
  State<AgentDefinitionEditor> createState() => _AgentDefinitionEditorState();
}

class _ScriptDraft {
  final String key = UniqueKey().toString();
  final Json original;
  late final TextEditingController id,
      path,
      interpreter,
      description,
      timeout,
      code;
  _ScriptDraft(Json data, String source) : original = data {
    id = TextEditingController(text: '${data['id'] ?? ''}');
    path = TextEditingController(text: '${data['path'] ?? ''}');
    interpreter = TextEditingController(
      text: '${data['interpreter'] ?? 'python3'}',
    );
    description = TextEditingController(text: '${data['description'] ?? ''}');
    timeout = TextEditingController(text: '${data['timeoutSeconds'] ?? 60}');
    code = TextEditingController(text: source);
  }
  Json get definition => {
    ...original,
    'id': id.text.trim(),
    'path': path.text.trim(),
    'interpreter': interpreter.text.trim(),
    'description': description.text,
    'timeoutSeconds': int.tryParse(timeout.text) ?? 0,
  };
  void dispose() {
    for (final c in [id, path, interpreter, description, timeout, code]) {
      c.dispose();
    }
  }
}

class _AgentDefinitionEditorState extends State<AgentDefinitionEditor> {
  late final TextEditingController id, name, version, prompt;
  late final Set<String> tools, skills, servers;
  late final List<_ScriptDraft> scripts;
  late bool allServers;
  bool saving = false, dirty = false;
  String? error;
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    final data = widget.original ?? {};
    id = TextEditingController(text: '${data['id'] ?? ''}');
    name = TextEditingController(text: '${data['name'] ?? ''}');
    version = TextEditingController(text: '${data['version'] ?? '1.0.0'}');
    prompt = TextEditingController(text: '${data['prompt'] ?? ''}');
    tools = (data['tools'] as List? ?? []).cast<String>().toSet();
    skills = (data['skills'] as List? ?? []).cast<String>().toSet();
    servers = (data['mcpServers'] as List? ?? []).cast<String>().toSet();
    allServers = !data.containsKey('mcpServers');
    scripts = (data['scripts'] as List? ?? []).map((raw) {
      final d = object(raw);
      return _ScriptDraft(d, widget.sources[d['path']] ?? '');
    }).toList();
  }

  @override
  void dispose() {
    for (final c in [id, name, version, prompt]) {
      c.dispose();
    }
    for (final script in scripts) {
      script.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (saving) return;
    if (!dirty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('关闭后，本次编辑不会保存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  Widget field(
    String label,
    TextEditingController controller, {
    bool locked = false,
    int lines = 1,
    String? hint,
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      readOnly: locked,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 8,
      onChanged: (_) => dirty = true,
      validator: required
          ? (v) => v == null || v.trim().isEmpty ? '请填写$label' : null
          : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        alignLabelWithHint: lines > 1,
      ),
    ),
  );
  Widget heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
  Widget choices(List<(String, String)> values, Set<String> selected) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: values
        .map(
          (entry) => FilterChip(
            label: Text(entry.$2),
            selected: selected.contains(entry.$1),
            onSelected: (value) => setState(() {
              dirty = true;
              value ? selected.add(entry.$1) : selected.remove(entry.$1);
            }),
          ),
        )
        .toList(),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 860,
        height: MediaQuery.sizeOf(context).height * .9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.original == null ? '新建' : '编辑'} ${widget.kind == 'agent' ? 'Agent' : 'Skill'}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: saving ? null : close,
                    icon: const Icon(Icons.close),
                    tooltip: '关闭编辑器',
                  ),
                ],
              ),
            ),
            const Divider(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: AbsorbPointer(
                absorbing: saving,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        heading('基本信息', 'ID 是唯一标识，创建后不能修改；名称可以重复。'),
                        field(
                          'ID',
                          id,
                          locked: widget.original != null,
                          hint: '例如 my.agent.assistant 或 my.skill.summary',
                          required: true,
                        ),
                        field('名称', name, required: true),
                        field('版本', version, required: true),
                        heading('指令', '描述职责、处理步骤和回答方式，支持 Markdown。'),
                        field('指令内容', prompt, lines: 7),
                        heading('业务工具', '只开放选中的工具；已有的写操作仍需确认。'),
                        choices([
                          ('search', '搜索资料'),
                          ('read_source', '读取来源'),
                          ('conversations', '查看会话'),
                          ('history', '读取历史'),
                          ('contacts', '查询联系人'),
                          ('send_message', '发送消息'),
                          ('create_document', '创建文档'),
                          ('create_task', '创建待办'),
                          for (final t in tools.where(
                            (t) => !agentTools.any(
                              (v) => v['function']['name'] == t,
                            ),
                          ))
                            (t, '$t（当前不可用）'),
                        ], tools),
                        if (widget.kind == 'agent') ...[
                          heading('引用技能', '选中要组合使用的 skill；停用或缺失的技能会影响运行。'),
                          if (widget.skills.isEmpty && skills.isEmpty)
                            const Text('暂无 skill，可先创建后再回来选择。'),
                          choices([
                            for (final s in widget.skills)
                              (
                                s['id'] as String,
                                '${s['name']} · ${s['id']}${s['enabled'] == true ? '' : '（已停用）'}',
                              ),
                            for (final s in skills.where(
                              (id) => !widget.skills.any((v) => v['id'] == id),
                            ))
                              (s, '$s（缺失）'),
                          ], skills),
                        ],
                        heading(
                          'MCP 范围',
                          '仅连接已启用的服务器；运行时合并 Agent 与引用技能中的显式列表。',
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('不限定 MCP 服务器'),
                          value: allServers,
                          onChanged: (value) => setState(() {
                            allServers = value;
                            dirty = true;
                          }),
                        ),
                        if (!allServers) ...[
                          const Text('不选择任何服务器表示空列表。'),
                          const SizedBox(height: 8),
                          choices([
                            for (final s in widget.servers)
                              (s['id'] as String, '${s['name']} · ${s['id']}'),
                            for (final s in servers.where(
                              (id) => !widget.servers.any((v) => v['id'] == id),
                            ))
                              (s, '$s（未配置）'),
                          ], servers),
                        ],
                        heading('本地脚本', '直接编写脚本代码。保存不会开启本地执行权限，也不会执行脚本。'),
                        for (final script in scripts)
                          Card(
                            key: ValueKey(script.key),
                            margin: const EdgeInsets.only(bottom: 16),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '脚本 ${scripts.indexOf(script) + 1}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '移除此脚本',
                                        onPressed: () => setState(() {
                                          scripts.remove(script);
                                          dirty = true;
                                          // Dispose after fields have been removed from the widget tree.
                                          WidgetsBinding.instance
                                              .addPostFrameCallback(
                                                (_) => script.dispose(),
                                              );
                                        }),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                  field('脚本 ID', script.id, required: true),
                                  field(
                                    '文件路径',
                                    script.path,
                                    hint: '例如 scripts/main.py',
                                    required: true,
                                  ),
                                  field(
                                    '解释器',
                                    script.interpreter,
                                    required: true,
                                  ),
                                  field(
                                    '超时（秒）',
                                    script.timeout,
                                    hint: '1–300 秒',
                                  ),
                                  field('脚本说明', script.description),
                                  field('脚本代码', script.code, lines: 8),
                                ],
                              ),
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: () => setState(() {
                              scripts.add(_ScriptDraft({}, ''));
                              dirty = true;
                            }),
                            icon: const Icon(Icons.add),
                            label: const Text('添加脚本'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: saving ? null : close,
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: saving ? null : save,
                    child: Text(saving ? '正在保存…' : '保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> save() async {
    if (!_form.currentState!.validate()) {
      _scroll.jumpTo(0);
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final definition = <String, dynamic>{
        ...?widget.original,
        'id': id.text.trim(),
        'name': name.text.trim(),
        'version': version.text.trim(),
        'kind': widget.kind,
        'protocol': 1,
        'prompt': prompt.text,
        'tools': tools.toList(),
        if (widget.kind == 'agent') 'skills': skills.toList(),
        'scripts': scripts.map((s) => s.definition).toList(),
      };
      if (allServers) {
        definition.remove('mcpServers');
      } else {
        definition['mcpServers'] = servers.toList();
      }
      final sources = <String, String>{};
      for (final script in scripts) {
        final path = script.path.text.trim();
        if (sources.containsKey(path) && sources[path] != script.code.text) {
          throw const FormatException('使用同一文件路径的脚本必须具有相同代码');
        }
        sources[path] = script.code.text;
      }
      // Detach draft JSON from the optimistic-concurrency snapshot.
      await widget.extensions.saveDefinition(
        object(jsonDecode(jsonEncode(definition))),
        sources,
        expected: widget.original,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
