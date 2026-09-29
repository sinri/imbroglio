import 'models.dart';

// Required by the v1.0.96 shortcuts, including their pre-flight checks.
const feishuReadScopes = {
  'im:chat:read',
  'im:message.group_msg:get_as_user',
  'im:message.p2p_msg:get_as_user',
  'im:message.reactions:read',
  'im:message:readonly',
  'contact:user:search',
  'search:message',
};
const feishuSendScopes = {'im:message.send_as_user', 'im:message'};
const feishuDocumentScopes = {'docx:document:readonly', 'search:docs:read'};
const feishuAgentScopes = {'docx:document:create', 'task:task:write'};
const feishuAllScopes = {
  ...feishuReadScopes,
  ...feishuSendScopes,
  ...feishuDocumentScopes,
  ...feishuAgentScopes,
};

Set<String> feishuScopes(Json user) => '${user['scope'] ?? ''}'
    .split(RegExp(r'\s+'))
    .where((s) => s.isNotEmpty)
    .toSet();

Json feishuUser(Json result) =>
    object(object(object(result['status'])['identities'])['user']);

bool feishuVerified(Json user) =>
    user['available'] == true &&
    user['verified'] == true &&
    ['ready', 'needs_refresh'].contains(user['status']) &&
    user['openId'] is String &&
    (user['openId'] as String).isNotEmpty;
