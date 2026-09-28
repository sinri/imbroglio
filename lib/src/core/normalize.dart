import 'dart:convert';
import 'models.dart';

Object? unwrap(Object? input) {
  var value = input;
  for (var i = 0; i < 8; i++) {
    if (value is String) {
      try {
        value = jsonDecode(value);
        continue;
      } catch (_) {
        return value;
      }
    }
    if (value is! Map) return value;
    final j = object(value);
    if (j['ok'] == false ||
        j['success'] == false ||
        j['isError'] == true ||
        (j['errcode'] is num && j['errcode'] != 0) ||
        (j['code'] is num && j['code'] != 0 && j['code'] != 200)) {
      throw AppFailure(
        'upstream',
        '${object(j['error'])['message'] ?? j['message'] ?? j['msg'] ?? j['errmsg'] ?? '平台调用失败'}',
      );
    }
    if (j.containsKey('data')) {
      value = j['data'];
      continue;
    }
    if (j['result'] != null) {
      value = j['result'];
      if (value is List &&
          value.length == 1 &&
          value.first is Map &&
          value.first['type'] == 'text') {
        value = value.first['text'];
      }
      continue;
    }
    if (j['content'] is List &&
        (j['content'] as List).isNotEmpty &&
        j['content'][0] is Map &&
        j['content'][0]['type'] == 'text' &&
        j.length <= 3) {
      value = j['content'][0]['text'];
      continue;
    }
    return value;
  }
  return value;
}

List<Json> rows(Object? value) {
  final v = unwrap(value);
  if (v is List) return v.whereType<Map>().map(object).toList();
  if (v is Map) {
    for (final key in [
      'items',
      'messages',
      'conversations',
      'conversationList',
      'messageList',
      'list',
      'docs',
      'files',
      'users',
      'profiles',
      'results',
    ]) {
      if (v[key] is List) {
        return (v[key] as List).whereType<Map>().map(object).toList();
      }
    }
  }
  return [];
}

String field(Json j, List<String> names, [String fallback = '']) {
  for (final name in names) {
    final v = j[name];
    if (v != null && v.toString().isNotEmpty) return v.toString();
  }
  return fallback;
}

int timestamp(Object? v) {
  final number = num.tryParse('$v');
  if (number != null) {
    return (number < 100000000000 ? number * 1000 : number).toInt();
  }
  return DateTime.tryParse('$v')?.millisecondsSinceEpoch ?? 0;
}

String bodyText(Object? value) {
  if (value is String) {
    try {
      return bodyText(jsonDecode(value));
    } catch (_) {
      return value;
    }
  }
  if (value is List) return value.map(bodyText).join('\n');
  if (value is Map) {
    for (final key in [
      'text',
      'markdown',
      'content',
      'richText',
      'title',
      'body',
    ]) {
      if (value[key] != null) return bodyText(value[key]);
    }
    return jsonEncode(value);
  }
  return value?.toString() ?? '';
}

Conversation normalizeConversation(String account, Json j) {
  final id = field(j, [
    'chat_id',
    'openConversationId',
    'conversationId',
    'id',
  ]);
  if (id.isEmpty) throw const AppFailure('contract', '会话响应缺少 ID，CLI 契约可能已变化');
  final type = field(j, ['chat_type', 'type', 'conversationType', 'kind']);
  return Conversation(
    accountId: account,
    id: id,
    title: field(j, ['name', 'title', 'conversationTitle', 'nick'], id),
    kind: ['p2p', '1', 'single', 'o2o'].contains(type) ? 'p2p' : 'group',
    peerId: field(j, ['peerId', 'openDingTalkId', 'peerOpenDingTalkId']),
    updatedAt: timestamp(
      j['update_time'] ??
          j['lastModify'] ??
          j['modifyTime'] ??
          j['gmtModified'],
    ),
    unread: int.tryParse(field(j, ['unreadCount', 'unread_count'], '0')) ?? 0,
  );
}

Message normalizeMessage(String account, String conversation, Json input) {
  var j = input;
  if (j['message'] is Map) j = {...j, ...object(j['message'])};
  final id = field(j, [
    'message_id',
    'openMessageId',
    'messageId',
    'msgId',
    'id',
  ]);
  if (id.isEmpty) throw const AppFailure('contract', '消息响应缺少 ID，未写入缓存');
  final sender = object(j['sender']);
  return Message(
    accountId: account,
    conversationId: field(j, [
      'chat_id',
      'openConversationId',
      'conversationId',
    ], conversation),
    id: id,
    text: bodyText(j['content'] ?? j['text'] ?? j['body']),
    timestamp: timestamp(
      j['create_time'] ??
          j['createdAt'] ??
          j['sendTime'] ??
          j['gmtCreate'] ??
          j['timestamp'],
    ),
    sender: field(j, [
      'sender_name',
      'senderName',
      'senderNick',
      'nick',
    ], field(sender, ['name', 'id'])),
    senderId: field(j, [
      'sender_id',
      'senderId',
      'senderOpenDingTalkId',
    ], field(sender, ['id', 'open_id'])),
    kind: field(j, ['message_type', 'msgType', 'type'], 'text'),
    extra: {'raw': j},
  );
}

String findResourceId(Object? value, [int depth = 0]) {
  if (depth > 8) return '';
  if (value is String) {
    try {
      return findResourceId(jsonDecode(value), depth + 1);
    } catch (_) {
      return '';
    }
  }
  if (value is Map) {
    for (final key in ['file_key', 'image_key', 'mediaId', 'media_id']) {
      if (value[key] is String && (value[key] as String).isNotEmpty) {
        return value[key];
      }
    }
    for (final child in value.values) {
      final found = findResourceId(child, depth + 1);
      if (found.isNotEmpty) return found;
    }
  }
  if (value is List) {
    for (final child in value) {
      final found = findResourceId(child, depth + 1);
      if (found.isNotEmpty) return found;
    }
  }
  return '';
}
