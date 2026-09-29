import 'models.dart';

/// Name-based exclusions from automatic message ingestion.
class ConversationBlacklistRule {
  final String pattern, accountId;
  final bool regex;
  late final RegExp matcher = _compile();

  ConversationBlacklistRule({
    required this.pattern,
    this.accountId = '',
    this.regex = false,
  }) {
    if (pattern.trim().isEmpty) throw const FormatException('规则不能为空');
    matcher; // Validate before persisting.
  }

  RegExp _compile() => RegExp(
    regex
        ? pattern
        : '^${pattern.split('').map((c) => c == '*'
              ? '.*'
              : c == '?'
              ? '.'
              : RegExp.escape(c)).join()}\$',
    dotAll: true,
  );

  bool matches(Conversation c) =>
      (accountId.isEmpty || accountId == c.accountId) &&
      matcher.hasMatch(c.title);

  factory ConversationBlacklistRule.fromJson(Json j) =>
      ConversationBlacklistRule(
        pattern: j['pattern'] as String,
        accountId: j['accountId'] as String? ?? '',
        regex: j['regex'] == true,
      );

  Json toJson() => {'pattern': pattern, 'accountId': accountId, 'regex': regex};
}
