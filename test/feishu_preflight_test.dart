import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/feishu_auth.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'feishu_auth_test.dart' show AuthWorkspace;
import 'sync_test.dart' show FakeRpc;

void main() {
  const account = AccountRef(
    id: 'a',
    platform: 'feishu',
    label: 'test',
    userId: 'ou_test',
  );
  late AuthWorkspace w;
  late Json user;
  late List<String> calls;
  late Set<String> enabled;
  late List<String> requested;
  setUp(() async {
    calls = [];
    requested = [];
    enabled = {
      ...feishuReadScopes,
      ...feishuSendScopes,
      ...feishuDocumentScopes,
    };
    user = {
      'available': true,
      'verified': true,
      'status': 'ready',
      'openId': 'ou_test',
      'scope': feishuReadScopes.join(' '),
    };
    w = AuthWorkspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [account];
    await w.store.init();
    w.rpc = FakeRpc((method, args) {
      calls.add(method);
      if (method == 'auth.scopes') {
        return {'appId': 'app', 'userScopes': enabled.toList()};
      }
      if (method == 'auth.login') {
        requested = (args['scopes'] as List).cast<String>();
        user = {...user, 'scope': requested.join(' ')};
        return {'completed': true, 'userId': 'ou_test'};
      }
      return {
        'status': {
          'appId': 'app',
          'identities': {'user': user},
        },
      };
    });
  });
  tearDown(() => w.close());

  test('valid basic authorization reuses identity without login', () async {
    final result = await w.authenticate(account);
    expect(calls, ['auth.status', 'auth.scopes']);
    expect(result['userId'], 'ou_test');
    expect(result['canSend'], false);
  });

  test(
    'optional selection requests existing union selected scopes, never all domains',
    () async {
      user['scope'] = {...feishuReadScopes, 'existing:optional'}.join(' ');
      final result = await w.authenticate(
        account,
        onPermissions: (preview) async {
          expect(preview['canReuse'], true);
          expect(preview['appScopes'], containsAll(feishuSendScopes));
          return feishuSendScopes.toList();
        },
      );
      expect(requested.toSet(), {
        ...feishuReadScopes,
        ...feishuSendScopes,
        'existing:optional',
      });
      expect(requested, isNot(contains('search:docs:read')));
      expect(result['canSend'], true);
    },
  );

  test('already granted selections do not launch login', () async {
    user['scope'] = enabled.join(' ');
    await w.authenticate(
      account,
      onPermissions: (_) async => feishuSendScopes.toList(),
    );
    expect(calls, ['auth.status', 'auth.scopes']);
  });

  test(
    'explicit renewal preserves all grants even with no optional selection',
    () async {
      user['scope'] = {...feishuReadScopes, ...feishuDocumentScopes}.join(' ');
      await w.authenticate(account, config: {'forceAuthorization': true});
      expect(calls, [
        'auth.status',
        'auth.scopes',
        'auth.login',
        'auth.status',
      ]);
      expect(requested.toSet(), {...feishuReadScopes, ...feishuDocumentScopes});
    },
  );

  test('different app scope response is rejected before login', () async {
    final original = w.rpc;
    w.rpc = FakeRpc(
      (method, args) => method == 'auth.scopes'
          ? {'appId': 'another-app', 'userScopes': enabled.toList()}
          : original.call(method, args),
    );
    await expectLater(w.authenticate(account), throwsA(isA<AppFailure>()));
    expect(calls, isNot(contains('auth.login')));
  });

  test('declining permission selection cancels without login', () async {
    await expectLater(
      w.authenticate(account, onPermissions: (_) async => null),
      throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(calls, ['auth.status', 'auth.scopes']);
  });

  test(
    'app missing optional scope keeps read-only connection possible',
    () async {
      enabled.removeAll(feishuSendScopes);
      await w.authenticate(account, onPermissions: (_) async => []);
      expect(calls, ['auth.status', 'auth.scopes']);
    },
  );

  test(
    'unavailable requested scopes do not start user authorization',
    () async {
      enabled.removeAll(feishuSendScopes);
      await expectLater(
        w.authenticate(
          account,
          onPermissions: (_) async => feishuSendScopes.toList(),
        ),
        throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'permission')),
      );
      expect(calls, isNot(contains('auth.login')));
    },
  );

  for (final method in ['auth.status', 'auth.scopes']) {
    test(
      '$method network failure does not trigger login or initialization',
      () async {
        final original = w.rpc;
        w.rpc = FakeRpc((name, args) {
          if (name == method) throw const AppFailure('network', 'offline');
          return original.call(name, args);
        });
        await expectLater(w.authenticate(account), throwsA(isA<AppFailure>()));
        expect(calls, isNot(contains('auth.login')));
        expect(calls, isNot(contains('auth.configure')));
      },
    );
  }

  test('unverifiable token is not treated as missing authorization', () async {
    user = {...user, 'status': 'verify_failed', 'verified': false};
    await expectLater(w.authenticate(account), throwsA(isA<AppFailure>()));
    expect(calls, ['auth.status']);
  });

  test('different bound user cannot silently replace account', () async {
    user['openId'] = 'ou_other';
    await expectLater(
      w.authenticate(account),
      throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'identity')),
    );
    expect(calls, ['auth.status']);
  });

  test(
    'cancel while checking scopes stops before permission selection and login',
    () async {
      final entered = Completer<void>();
      final pending = Completer<Json>();
      final original = w.rpc;
      w.rpc = FakeRpc((method, args) {
        if (method == 'auth.scopes') {
          entered.complete();
          return pending.future;
        }
        return original.call(method, args);
      });
      var selected = false;
      final attempt = w.authenticate(
        account,
        onPermissions: (_) async {
          selected = true;
          return [];
        },
      );
      final assertion = expectLater(
        attempt,
        throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      await entered.future;
      w.cancelAuthentication(account);
      await assertion;
      pending.complete({'appId': 'app', 'userScopes': enabled.toList()});
      await Future<void>.delayed(Duration.zero);
      expect(selected, false);
      expect(calls, isNot(contains('auth.login')));
    },
  );
}
