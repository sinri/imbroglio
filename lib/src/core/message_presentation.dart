import 'dart:convert';
import 'models.dart';
import 'normalize.dart';

/// Presentation is derived at read time so old cached messages also benefit.
class MessagePresentation {
  final String text;
  final bool markdown;
  const MessagePresentation(this.text, {this.markdown = false});
}

const _formattedTypes = {'markdown', 'md', 'post', 'richtext', 'rich_text'};
const _typeKeys = ['message_type', 'msgType', 'msgtype', 'messageType', 'type'];
const _bodyKeys = ['content', 'text', 'body', 'msgContent'];

MessagePresentation messagePresentation(Message message) {
  if (!{'text', '', ..._formattedTypes}.contains(message.kind)) {
    return MessagePresentation(message.text);
  }
  var raw = object(message.extra['raw']);
  if (raw['message'] is Map) raw = {...raw, ...object(raw['message'])};
  final typed =
      _formattedTypes.contains(message.kind) ||
      _formattedTypes.contains(field(raw, _typeKeys).toLowerCase());
  final formatted = _formattedBody(raw, 0, typed);
  if (formatted != null && formatted.isNotEmpty) {
    return MessagePresentation(formatted, markdown: true);
  }
  return MessagePresentation(
    message.text,
    markdown: typed || looksLikeMarkdown(message.text),
  );
}

/// Only strong, paired syntax or multiple list items triggers inference.
/// A single bullet, identifier_with_underscores or ordinary URL stays plain.
bool looksLikeMarkdown(String text) =>
    RegExp(
      r'^\s{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*\n\s{0,3}\1\s*$',
      multiLine: true,
    ).hasMatch(text) ||
    RegExp(r'^ {0,3}#{1,6} \S', multiLine: true).hasMatch(text) ||
    RegExp(r'\*\*[^*\n]+\*\*|__[^_\n]+__').hasMatch(text) ||
    RegExp(r'\[[^\]\n]+\]\(https?://[^\s)]+\)').hasMatch(text) ||
    RegExp(
      r'^\s*\|?.+\|.+\n\s*\|?\s*:?-{3,}:?\s*\|',
      multiLine: true,
    ).hasMatch(text) ||
    RegExp(
      r'^ {0,3}(?:[-+*]|\d+\.) \S.*\n {0,3}(?:[-+*]|\d+\.) \S',
      multiLine: true,
    ).hasMatch(text);

Object? _decode(Object? value) {
  if (value is String) {
    try {
      return jsonDecode(value);
    } on FormatException {
      return value;
    }
  }
  return value;
}

String? _formattedBody(Object? input, int depth, bool typed) {
  if (depth > 12) return null;
  final value = _decode(input);
  if (value is String) return typed ? value : null;
  if (value is List) {
    if (typed || _hasRichNode(value, 0)) return _richMarkdown(value, 0);
    return null;
  }
  if (value is! Map) return null;
  final j = object(value);
  final type = field(j, _typeKeys).toLowerCase();
  if (_formattedTypes.contains(type)) typed = true;
  if (j['markdown'] != null) {
    return richMessageText(j['markdown']);
  }
  if (j['richText'] != null || j['rich_text'] != null) {
    return _richMarkdown(j['richText'] ?? j['rich_text'], 0);
  }
  if (_hasRichNode(j, 0)) return _richMarkdown(j, 0);
  for (final locale in ['zh_cn', 'en_us', 'ja_jp']) {
    if (j[locale] is Map) return _formattedBody(j[locale], depth + 1, typed);
  }
  for (final key in _bodyKeys) {
    if (j[key] == null) continue;
    final body = _formattedBody(j[key], depth + 1, typed);
    if (body != null) return body;
  }
  return null;
}

bool _hasRichNode(Object? input, int depth) {
  if (depth > 12) return false;
  final value = _decode(input);
  if (value is List) return value.any((v) => _hasRichNode(v, depth + 1));
  if (value is! Map) return false;
  if ({
    'text',
    'a',
    'at',
    'img',
    'image',
    'md',
    'code_block',
    'hr',
  }.contains(value['tag'])) {
    return true;
  }
  return [
    'content',
    'body',
    'elements',
    'zh_cn',
    'en_us',
    'ja_jp',
  ].any((key) => _hasRichNode(value[key], depth + 1));
}

String _escape(String text) => text.replaceAllMapped(
  RegExp(r'[\\`*_{}\[\]<>()#+.!|~>-]'),
  (m) => '\\${m[0]}',
);

/// Convert supported structured nodes without interpreting literal text as MD.
String _richMarkdown(Object? input, int depth) {
  if (depth > 12) return '';
  final value = _decode(input);
  if (value is String) return _escape(value);
  if (value is List) {
    return value
        .map((v) => _richMarkdown(v, depth + 1))
        .join(value.any((v) => v is List) ? '\n\n' : '');
  }
  if (value is! Map) return '';
  final j = object(value);
  for (final locale in ['zh_cn', 'en_us', 'ja_jp']) {
    if (j[locale] is Map) return _richMarkdown(j[locale], depth + 1);
  }
  final tag = '${j['tag'] ?? j['type'] ?? ''}';
  if (tag == 'md') return '${j['text'] ?? ''}';
  if (tag == 'hr') return '\n\n---\n\n';
  if (tag == 'at') {
    return _escape('@${j['user_name'] ?? j['name'] ?? j['user_id'] ?? '成员'}');
  }
  if (tag == 'img' ||
      tag == 'image' ||
      j['image_key'] != null ||
      j['mediaId'] != null) {
    final id = field(j, ['image_key', 'mediaId', 'media_id']);
    return id.isEmpty
        ? '[图片]'
        : '\n\n[图片消息](mediaId=${Uri.encodeComponent(id)})\n\n';
  }
  if (tag == 'code_block') {
    final code = '${j['text'] ?? ''}';
    var fence = '```';
    while (code.contains(fence)) {
      fence += '`';
    }
    return '\n\n$fence\n$code\n$fence\n\n';
  }
  if (tag == 'a') {
    final href = '${j['href'] ?? ''}';
    final label = _escape('${j['text'] ?? href}');
    final uri = Uri.tryParse(href);
    if (uri != null && ['http', 'https'].contains(uri.scheme)) {
      return '[$label](${href.replaceAll(' ', '%20').replaceAll('(', '%28').replaceAll(')', '%29')})';
    }
    return label;
  }
  if (j['text'] is String) {
    var text = _escape(j['text'] as String);
    final styles = j['style'] is List ? j['style'] as List : const [];
    if (styles.contains('bold')) text = '**$text**';
    if (styles.contains('italic')) text = '*$text*';
    if (styles.contains('lineThrough') || styles.contains('strikethrough')) {
      text = '~~$text~~';
    }
    return text;
  }
  final title = j['title'] is String ? '**${_escape(j['title'])}**\n\n' : '';
  for (final key in ['content', 'richText', 'body', 'elements']) {
    if (j[key] != null) return '$title${_richMarkdown(j[key], depth + 1)}';
  }
  return '$title${_escape(richMessageText(j))}';
}
