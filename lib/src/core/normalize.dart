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
      'members',
      'memberList',
      'userList',
      'userInfos',
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

/// Message timestamps are platform send/create times, never sync times.
int messageTimestamp(Json input) {
  final j = input['message'] is Map
      ? {...input, ...object(input['message'])}
      : input;
  for (final key in [
    'create_time',
    'createdAt',
    'createTime',
    'sendTime',
    'gmtCreate',
    'timestamp',
  ]) {
    final time = timestamp(j[key]);
    if (time > 0) return time;
  }
  return 0;
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
      j['last_message_time'] ??
          j['lastMessageTime'] ??
          j['active_time'] ??
          j['update_time'] ??
          j['lastModify'] ??
          j['modifyTime'] ??
          j['gmtModified'],
    ),
    unread: int.tryParse(field(j, ['unreadCount', 'unread_count'], '0')) ?? 0,
    unreadIsLocal:
        !j.containsKey('unreadCount') && !j.containsKey('unread_count'),
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
    text: richMessageText(
      j['content'] ?? j['text'] ?? j['body'] ?? j['msgContent'],
    ),
    timestamp: messageTimestamp(j),
    sender: field(
      j,
      ['sender_name', 'senderName', 'senderNick', 'nick'],
      field(sender, [
        'name',
        'display_name',
      ], j['sender'] is String ? j['sender'] : ''),
    ),
    senderId: field(j, [
      'sender_id',
      'senderId',
      'senderOpenDingTalkId',
    ], field(sender, ['id', 'open_id'])),
    kind: field(j, ['message_type', 'msgType', 'type'], 'text').toLowerCase(),
    extra: {
      'raw': j,
      'avatar': avatarUrl(
        sender['avatar_url'] ??
            sender['avatarUrl'] ??
            sender['avatar'] ??
            j['senderAvatar'] ??
            j['avatarUrl'],
      ),
      'replyId': field(j, [
        'parent_id',
        'root_id',
        'replyToMessageId',
        'repliedMessageId',
      ]),
      'isOwn':
          j['isSelf'] == true ||
          j['is_self'] == true ||
          sender['is_self'] == true,
      'senderLookupId': field(j, [
        'senderUserId',
        'senderId',
        'sender_id',
      ], field(sender, ['id', 'open_id'])),
    },
  );
}

class MessageImageReference {
  final int start, end;
  final String resourceId;
  const MessageImageReference(this.start, this.end, this.resourceId);
}

final _messageImagePattern = RegExp(
  r'\[图片消息\]\(\s*mediaId\s*=\s*([^\s)]+)\s*\)',
);

List<MessageImageReference> messageImageReferences(String text) =>
    _messageImagePattern
        .allMatches(text)
        .map((match) {
          var id = match.group(1)!;
          if (id.length > 1 &&
              ((id.startsWith('"') && id.endsWith('"')) ||
                  (id.startsWith("'") && id.endsWith("'")))) {
            id = id.substring(1, id.length - 1);
          }
          try {
            id = Uri.decodeComponent(id);
          } on FormatException {
            /* Keep opaque IDs intact. */
          }
          return MessageImageReference(match.start, match.end, id);
        })
        .where((ref) => ref.resourceId.isNotEmpty)
        .toList();

String findResourceId(Object? value, [int depth = 0]) {
  if (depth > 8) return '';
  if (value is String) {
    try {
      return findResourceId(jsonDecode(value), depth + 1);
    } catch (_) {
      return messageImageReferences(value).firstOrNull?.resourceId ?? '';
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

/// Render the structured text nodes used by posts/cards without exposing JSON.
String richMessageText(Object? value, [int depth = 0]) {
  if (depth > 12) return '';
  if (value is String) {
    try {
      return richMessageText(jsonDecode(value), depth + 1);
    } catch (_) {
      return value;
    }
  }
  if (value is List) {
    return value
        .map((e) => richMessageText(e, depth + 1))
        .join(value.any((e) => e is List) ? '\n' : '');
  }
  if (value is Map) {
    final j = object(value);
    final tag = '${j['tag'] ?? ''}';
    if (tag == 'at') {
      return '@${j['user_name'] ?? j['name'] ?? j['user_id'] ?? '成员'}';
    }
    if (tag == 'img' || tag == 'image') return '[图片]';
    if (tag == 'emotion') return '[${j['emoji_type'] ?? '表情'}]';
    if (tag == 'a') {
      return '${j['text'] ?? j['href'] ?? ''} (${j['href'] ?? ''})';
    }
    for (final locale in ['zh_cn', 'en_us', 'ja_jp']) {
      if (j[locale] is Map) return richMessageText(j[locale], depth + 1);
    }
    final parts = <String>[];
    if (j['title'] != null) parts.add(richMessageText(j['title'], depth + 1));
    for (final key in [
      'text',
      'markdown',
      'content',
      'richText',
      'body',
      'elements',
    ]) {
      if (j[key] != null) {
        parts.add(richMessageText(j[key], depth + 1));
        break;
      }
    }
    if (parts.isNotEmpty) return parts.where((s) => s.isNotEmpty).join('\n');
    return field(j, ['file_name', 'fileName', 'name']);
  }
  return value?.toString() ?? '';
}

/// Attachment metadata may be nested in JSON-encoded message bodies.
Json attachmentDetails(Object? value, [int depth = 0]) {
  if (depth > 8) return {};
  if (value is String) {
    try {
      return attachmentDetails(jsonDecode(value), depth + 1);
    } catch (_) {
      return {};
    }
  }
  if (value is Map) {
    final j = object(value);
    final name = field(j, ['file_name', 'fileName']);
    final size = int.tryParse(field(j, ['file_size', 'fileSize', 'size']));
    if (name.isNotEmpty) return {'name': name, 'size': size};
    for (final child in value.values) {
      final result = attachmentDetails(child, depth + 1);
      if (result.isNotEmpty) return result;
    }
  }
  if (value is List) {
    for (final child in value) {
      final result = attachmentDetails(child, depth + 1);
      if (result.isNotEmpty) return result;
    }
  }
  return {};
}

/// Older cached messages may predate senderLookupId and normalized avatars.
String senderLookupId(Message m) {
  final raw = object(m.extra['raw']);
  final sender = object(raw['sender']);
  return field(
    m.extra,
    ['senderLookupId'],
    field(raw, [
      'senderUserId',
      'senderId',
      'sender_id',
    ], field(sender, ['id', 'open_id'], m.senderId)),
  );
}

String messageSenderName(Message m) {
  if (m.sender.isNotEmpty && m.sender != m.senderId) return m.sender;
  final raw = object(m.extra['raw']);
  final sender = object(raw['sender']);
  return field(
    raw,
    ['sender_name', 'senderName', 'senderNick', 'nick'],
    field(
      sender,
      ['name', 'display_name'],
      raw['sender'] is String && raw['sender'] != m.senderId
          ? raw['sender']
          : '',
    ),
  );
}

String avatarUrl(Object? value) {
  if (value is String) {
    final url = value.trim();
    final uri = Uri.tryParse(url);
    return uri != null &&
            ['https', 'http'].contains(uri.scheme) &&
            uri.host.isNotEmpty
        ? url
        : '';
  }
  if (value is Map) {
    for (final key in [
      'avatar_240',
      'avatar_72',
      'avatar_640',
      'url',
      'avatarUrl',
      'avatar_url',
      'avatar',
      'icon',
      'orgUserAvatar',
    ]) {
      final url = avatarUrl(value[key]);
      if (url.isNotEmpty) return url;
    }
  }
  return '';
}

String messageSenderAvatar(Message m) {
  final raw = object(m.extra['raw']);
  final sender = object(raw['sender']);
  for (final value in [
    m.extra['avatar'],
    sender['avatar'],
    sender['avatar_url'],
    sender['avatarUrl'],
    raw['senderAvatar'],
    raw['avatarUrl'],
  ]) {
    final url = avatarUrl(value);
    if (url.isNotEmpty) return url;
  }
  return '';
}

Json normalizeSenderProfile(Json j) {
  final employee = object(j['orgEmployeeModel']);
  return {
    'id': field(j, [
      'open_id',
      'user_id',
      'userId',
      'id',
      'openDingTalkId',
      'openDingtalkId',
    ], field(employee, ['orgUserId'])),
    'name': field(j, [
      'name',
      'display_name',
      'localized_name',
      'nick',
      'displayName',
    ], field(employee, ['orgUserName'])),
    'avatar': avatarUrl(j).isNotEmpty ? avatarUrl(j) : avatarUrl(employee),
    if (field(j, [
      'avatarMediaId',
    ], field(employee, ['avatarMediaId'])).isNotEmpty)
      'avatarResourceId': field(j, [
        'avatarMediaId',
      ], field(employee, ['avatarMediaId'])),
  };
}
