import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/agent_limits.dart';

void main() {
  test('Qwen accepts history beyond the legacy character limit', () {
    final history = <Json>[
      {'role': 'user', 'content': 'a' * 200000},
    ];
    AgentLimits('qwen3.8-flash').validate(history, history, []);
    expect(
      () => AgentLimits('other').validate(history, history, []),
      throwsA(isA<AppFailure>()),
    );
  });

  test('Qwen budget includes system messages and tool definitions', () {
    final limits = AgentLimits('qwen3.8-flash');
    final messages = <Json>[
      {'role': 'system', 'content': 'a' * 400000},
    ];
    final tools = <Json>[
      {'description': 'b' * 210000},
    ];
    limits.validate([], messages, []);
    expect(
      () => limits.validate([], messages, tools),
      throwsA(isA<AppFailure>()),
    );
  });

  test('Qwen uses UTF-8 bytes and enforces the reserved-budget boundary', () {
    final limits = AgentLimits('qwen3.8-flash');
    final messages = <Json>[
      {'role': 'user', 'content': ''},
    ];
    final overhead =
        utf8.encode(jsonEncode({'messages': messages})).length + 4096;
    messages.first['content'] = 'a' * (AgentLimits.inputBudget - overhead);
    limits.validate(messages, messages, []);
    messages.first['content'] = '${messages.first['content']}a';
    expect(
      () => limits.validate(messages, messages, []),
      throwsA(isA<AppFailure>()),
    );
    messages.first['content'] = '中' * 210000;
    expect(
      () => limits.validate(messages, messages, []),
      throwsA(isA<AppFailure>()),
    );
  });
}
