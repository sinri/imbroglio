import 'dart:convert';
import 'dart:math';

typedef Json = Map<String, dynamic>;
Json object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String newId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String compositeKey(String account, String id) => jsonEncode([account, id]);

class AccountRef {
  final String id, platform, label, profile, organization, userId;
  final bool enabled;
  final bool signedOut;
  final bool canSend;
  const AccountRef({
    required this.id,
    required this.platform,
    required this.label,
    this.profile = '',
    this.organization = '',
    this.userId = '',
    this.enabled = true,
    this.signedOut = false,
    this.canSend = true,
  });
  factory AccountRef.fromJson(Json j) => AccountRef(
    id: j['id'],
    platform: j['platform'],
    label: j['label'],
    profile: j['profile'] ?? '',
    organization: j['organization'] ?? '',
    userId: j['userId'] ?? '',
    enabled: j['enabled'] ?? true,
    signedOut: j['signedOut'] ?? false,
    canSend: j['canSend'] ?? true,
  );
  Json toJson() => {
    'id': id,
    'platform': platform,
    'label': label,
    'profile': profile,
    'organization': organization,
    'userId': userId,
    'enabled': enabled,
    'signedOut': signedOut,
    'canSend': canSend,
  };
  AccountRef copyWith({
    String? label,
    String? profile,
    String? organization,
    String? userId,
    bool? enabled,
    bool? signedOut,
    bool? canSend,
  }) => AccountRef(
    id: id,
    platform: platform,
    label: label ?? this.label,
    profile: profile ?? this.profile,
    organization: organization ?? this.organization,
    userId: userId ?? this.userId,
    enabled: enabled ?? this.enabled,
    signedOut: signedOut ?? this.signedOut,
    canSend: canSend ?? this.canSend,
  );
}

class Conversation {
  final String accountId, id, title, kind, peerId, avatar;
  final int updatedAt, unread;
  final bool watched, unreadIsLocal;
  const Conversation({
    required this.accountId,
    required this.id,
    required this.title,
    this.kind = 'group',
    this.peerId = '',
    this.avatar = '',
    this.updatedAt = 0,
    this.unread = 0,
    this.watched = false,
    this.unreadIsLocal = true,
  });
  String get key => compositeKey(accountId, id);
  factory Conversation.fromJson(Json j) => Conversation(
    accountId: j['accountId'],
    id: j['id'],
    title: j['title'],
    kind: j['kind'] ?? 'group',
    peerId: j['peerId'] ?? '',
    avatar: j['avatar'] ?? '',
    updatedAt: j['updatedAt'] ?? 0,
    unread: j['unread'] ?? 0,
    watched: j['watched'] ?? false,
    unreadIsLocal: j['unreadIsLocal'] ?? true,
  );
  Json toJson() => {
    'accountId': accountId,
    'id': id,
    'title': title,
    'kind': kind,
    'peerId': peerId,
    'avatar': avatar,
    'updatedAt': updatedAt,
    'unread': unread,
    'watched': watched,
    'unreadIsLocal': unreadIsLocal,
  };
  Conversation copyWith({
    bool? watched,
    int? unread,
    int? updatedAt,
    bool? unreadIsLocal,
  }) => Conversation(
    accountId: accountId,
    id: id,
    title: title,
    kind: kind,
    peerId: peerId,
    avatar: avatar,
    watched: watched ?? this.watched,
    unreadIsLocal: unreadIsLocal ?? this.unreadIsLocal,
    unread: unread ?? this.unread,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class Message {
  final String accountId,
      conversationId,
      id,
      sender,
      senderId,
      text,
      kind,
      status;
  final int timestamp;
  final Json extra;
  const Message({
    required this.accountId,
    required this.conversationId,
    required this.id,
    required this.text,
    required this.timestamp,
    this.sender = '',
    this.senderId = '',
    this.kind = 'text',
    this.status = 'confirmed',
    this.extra = const {},
  });
  String get key => compositeKey(accountId, id);
  factory Message.fromJson(Json j) => Message(
    accountId: j['accountId'],
    conversationId: j['conversationId'],
    id: j['id'],
    text: j['text'],
    timestamp: j['timestamp'],
    sender: j['sender'] ?? '',
    senderId: j['senderId'] ?? '',
    kind: j['kind'] ?? 'text',
    status: j['status'] ?? 'confirmed',
    extra: object(j['extra']),
  );
  Json toJson() => {
    'accountId': accountId,
    'conversationId': conversationId,
    'id': id,
    'text': text,
    'timestamp': timestamp,
    'sender': sender,
    'senderId': senderId,
    'kind': kind,
    'status': status,
    'extra': extra,
  };
}

class ResourceRef {
  final String accountId, id, title, text, kind, url, conversationId;
  final int updatedAt;
  const ResourceRef({
    required this.accountId,
    required this.id,
    required this.title,
    this.text = '',
    this.kind = 'document',
    this.url = '',
    this.conversationId = '',
    this.updatedAt = 0,
  });
  factory ResourceRef.fromJson(Json j) => ResourceRef(
    accountId: j['accountId'],
    id: j['id'],
    title: j['title'],
    text: j['text'] ?? '',
    kind: j['kind'] ?? 'document',
    url: j['url'] ?? '',
    conversationId: j['conversationId'] ?? '',
    updatedAt: j['updatedAt'] ?? 0,
  );
  Json toJson() => {
    'accountId': accountId,
    'id': id,
    'title': title,
    'text': text,
    'kind': kind,
    'url': url,
    'conversationId': conversationId,
    'updatedAt': updatedAt,
  };
}

class SyncState {
  String mode;
  String _error;
  final pendingErrors = <String>[];
  String get error => _error;
  set error(String value) {
    _error = value;
    if (value.isNotEmpty && !pendingErrors.contains(value)) {
      pendingErrors.add(value);
    }
  }

  int lastSuccess, failures;
  bool gap;
  SyncState({
    this.mode = '定时同步',
    String error = '',
    this.lastSuccess = 0,
    this.failures = 0,
    this.gap = false,
  }) : _error = error {
    if (error.isNotEmpty) pendingErrors.add(error);
  }
  Json toJson() => {
    'mode': mode,
    'error': error,
    'lastSuccess': lastSuccess,
    'failures': failures,
    'gap': gap,
  };
}

class PluginManifest {
  final String id, name, version, kind;
  final int protocol;
  final Json data;
  PluginManifest(Json j)
    : id = j['id'] as String,
      name = j['name'] as String,
      version = j['version'] as String,
      kind = j['kind'] as String,
      protocol = j['protocol'] as int,
      data = j {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{1,63}$').hasMatch(id) ||
        protocol != 1 ||
        !['im', 'agent'].contains(kind)) {
      throw const FormatException('插件 ID、种类或协议不兼容');
    }
    if (kind == 'agent' && (j['prompt'] is! String || j['tools'] is! List)) {
      throw const FormatException('Agent 插件缺少 prompt/tools');
    }
  }
}

class AppFailure implements Exception {
  final String code, message;
  final int? retryAfter;
  const AppFailure(this.code, this.message, {this.retryAfter});
  @override
  String toString() => message;
  Json toJson() => {
    'code': code,
    'message': message,
    if (retryAfter != null) 'retryAfter': retryAfter,
  };
}
