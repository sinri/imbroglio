import 'dart:convert';
import 'dart:math' as math;

import '../core/models.dart';

/// https://help.aliyun.com/en/model-studio/qwen3-8-flash
/// Byte counting is a conservative local estimate, not Qwen tokenization.
class AgentLimits {
  AgentLimits(String model, {Object? contextLimit})
    : isQwenFlash = model.trim() == 'qwen3.8-flash',
      contextTokens = readContextLimit(contextLimit);

  static const contextOptions = <int, String>{
    32000: '32K',
    64000: '64K',
    128000: '128K',
    256000: '256K',
    512000: '512K',
    1000000: '1M',
  };
  static int readContextLimit(Object? value) =>
      value is int && contextOptions.containsKey(value) ? value : 1000000;

  final bool isQwenFlash;
  final int contextTokens;
  static const outputTokens = 131072;
  static const thinkingTokens = 262144;
  // Reserve the full thinking allowance because the provider controls its default.
  int get maxOutputTokens =>
      math.min(isQwenFlash ? outputTokens : 8192, contextTokens ~/ 4);
  int get inputBudget =>
      contextTokens -
      maxOutputTokens -
      (isQwenFlash ? math.min(thinkingTokens, contextTokens ~/ 3) : 0);

  int get responseCharacters =>
      isQwenFlash ? 64 * 1024 * 1024 : 2 * 1024 * 1024;

  void validate(List<Json> history, List<Json> messages, List<Json> tools) {
    final encoded = jsonEncode({
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
    });
    // Include JSON framing and additional room for provider message templates.
    final estimate = utf8.encode(encoded).length + 4096;
    if (estimate > inputBudget) {
      throw AppFailure(
        'context',
        '会话已达到本地保守输入预算（$inputBudget token，按 UTF-8 字节估算）；'
            '已预留输出和思考空间，请新建会话',
      );
    }
  }
}
