import 'dart:convert';

import '../core/models.dart';

/// https://help.aliyun.com/en/model-studio/qwen3-8-flash
/// Byte counting is a conservative local estimate, not Qwen tokenization.
class AgentLimits {
  AgentLimits(String model) : isQwenFlash = model.trim() == 'qwen3.8-flash';

  final bool isQwenFlash;
  static const contextTokens = 1000000;
  static const outputTokens = 131072;
  static const thinkingTokens = 262144;
  // Reserve the full thinking allowance because the provider controls its default.
  static const inputBudget = contextTokens - outputTokens - thinkingTokens;

  int get responseCharacters =>
      isQwenFlash ? 64 * 1024 * 1024 : 2 * 1024 * 1024;

  void validate(List<Json> history, List<Json> messages, List<Json> tools) {
    if (!isQwenFlash) {
      if (jsonEncode(history).length > 180000) {
        throw const AppFailure('context', '会话已达到上下文上限，请新建会话');
      }
      return;
    }
    final encoded = jsonEncode({
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
    });
    // Include JSON framing and additional room for provider message templates.
    final estimate = utf8.encode(encoded).length + 4096;
    if (estimate > inputBudget) {
      throw const AppFailure(
        'context',
        '会话已达到 Qwen3.8-Flash 的本地保守输入预算（606784 token，按 UTF-8 字节估算）；'
            '已预留输出和思考空间，请新建会话',
      );
    }
  }
}
