/// Value-level compatibility tests for the iOS AGY bridge.
/// No network, no carrier start-up: capability parsing, failure surfacing,
/// short retry and the strict Host wire payloads are all pure functions.
library;

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

Map<String, Object?> _description({required bool available, required bool includeAgy}) => <String, Object?>{
      'version': '0.2.0',
      'capabilities': <Object?>[
        acpCapability,
        if (includeAgy) agyCapability,
        'harness.remote.v1',
      ],
      'workspaceTypes': <Object?>[
        <String, Object?>{
          'id': agyBackend,
          'capability': agyCapability,
          'available': available,
        },
      ],
    };

void main() {
  group('AgyCapabilities compatibility', () {
    test('available:false is a diagnostic, not FEATURE_NOT_SUPPORTED', () {
      final capabilities = AgyCapabilities.fromDescription(_description(available: false, includeAgy: true));

      expect(capabilities.available, isTrue);
      expect(capabilities.agy, isTrue);
      expect(capabilities.unavailableBackends, contains(agyBackend));
      expect(capabilities.diagnostics, hasLength(1));
      expect(capabilities.diagnostics.single['code'], 'WORKSPACE_UNAVAILABLE');
      expect(capabilities.diagnostics.single['backend'], agyBackend);
    });

    test('an actually available backend has no diagnostics', () {
      final capabilities = AgyCapabilities.fromDescription(_description(available: true, includeAgy: true));

      expect(capabilities.available, isTrue);
      expect(capabilities.unavailableBackends, isEmpty);
      expect(capabilities.diagnostics, isEmpty);
    });

    test('an unadvertised AGY capability is still unavailable', () {
      final capabilities = AgyCapabilities.fromDescription(_description(available: true, includeAgy: false));

      expect(capabilities.acp, isTrue);
      expect(capabilities.agy, isFalse);
      expect(capabilities.available, isFalse);
    });

    test('a missing ACP capability still throws FEATURE_NOT_SUPPORTED', () {
      expect(
        () => AgyCapabilities.fromDescription(<String, Object?>{'capabilities': <Object?>[agyCapability]}),
        throwsA(isA<ClientModeError>().having((error) => error.code, 'code', 'FEATURE_NOT_SUPPORTED')),
      );
    });
  });

  group('failure surfacing', () {
    test('normalizes typed and untyped errors with a phase', () {
      final entry = agyFailureEntry(
        const AgyFailure('ACP_SESSION_NOT_LOADED', 'session not loaded'),
        phase: 'models',
      );
      expect(entry['code'], 'ACP_SESSION_NOT_LOADED');
      expect(entry['message'], contains('session not loaded'));
      expect(entry['phase'], 'models');

      final untyped = agyFailureEntry(StateError('boom'));
      expect(untyped['code'], 'ACP_ERROR');
      expect(untyped['message'], contains('boom'));
      expect(untyped.containsKey('phase'), isFalse);
    });

    test('fetch results carry failures as values', () {
      const ok = AgyFetchResult.value(<String, Object?>{'current': <String, Object?>{}});
      const failed = AgyFetchResult.failure(AgyFailure('EMPTY_MODEL_CATALOG', 'no models'));

      expect(ok.ok, isTrue);
      expect(ok.raw, isNotNull);
      expect(ok.failure, isNull);
      expect(failed.ok, isFalse);
      expect(failed.raw, isNull);
      expect(failed.failure, isA<AgyFailure>());
    });

    test('only transient codes are classified as retryable', () {
      expect(agyIsTransientError(const AgyFailure('ACP_WORKSPACE_UNAVAILABLE', 'binding')), isTrue);
      expect(agyIsTransientError(const AgyFailure('ACP_SESSION_NOT_LOADED', 'loading')), isTrue);
      expect(agyIsTransientError(const RemoteRpcException('TRANSPORT_CLOSED', 'closed')), isTrue);
      expect(agyIsTransientError(const AgyFailure('BAD_REQUEST', 'bad')), isFalse);
      expect(agyIsTransientError(const AgyFailure('model-unavailable', 'unknown')), isFalse);
    });
  });

  group('short retry', () {
    test('retries a transient error and returns the value', () async {
      var attempts = 0;
      final result = await agyShortRetry(
        () async {
          attempts += 1;
          if (attempts < 3) throw const AgyFailure('ACP_WORKSPACE_UNAVAILABLE', 'warming up');
          return 'ok';
        },
        delay: Duration.zero,
      );

      expect(result, 'ok');
      expect(attempts, 3);
    });

    test('does not retry a non-transient error', () async {
      var attempts = 0;
      await expectLater(
        agyShortRetry(
          () async {
            attempts += 1;
            throw const AgyFailure('BAD_REQUEST', 'bad');
          },
          delay: Duration.zero,
        ),
        throwsA(isA<AgyFailure>().having((error) => error.code, 'code', 'BAD_REQUEST')),
      );
      expect(attempts, 1);
    });

    test('rethrows the last error after exhausting attempts', () async {
      var attempts = 0;
      await expectLater(
        agyShortRetry(
          () async {
            attempts += 1;
            throw const AgyFailure('TIMEOUT', 'slow');
          },
          attempts: 2,
          delay: Duration.zero,
        ),
        throwsA(isA<AgyFailure>().having((error) => error.code, 'code', 'TIMEOUT')),
      );
      expect(attempts, 2);
    });
  });

  group('strict Host wire payloads', () {
    test('sessionList prebind uses path and never cwd', () {
      final params = agyPrebindParams('/Users/demo/project', limit: 500);

      expect(params['path'], '/Users/demo/project');
      expect(params['backend'], agyBackend);
      expect(params['limit'], 100);
      expect(params.containsKey('cwd'), isFalse);
    });

    test('session/prompt payload is strict and has no cwd', () {
      final params = agyPromptParams('native-1', 'hello', <Map<String, Object?>>[
        <String, Object?>{'type': 'image', 'data': 'AAAA'},
      ]);

      expect(params.containsKey('cwd'), isFalse);
      expect(params['sessionId'], 'native-1');
      expect(params['backend'], agyBackend);
      final blocks = params['prompt'] as List<Object?>;
      expect(blocks, hasLength(2));
      expect((blocks.first as Map<String, Object?>)['text'], 'hello');
    });

    test('dsh/selectModel payload is strict and has no cwd', () {
      final params = agySelectModelParams('native-1', 'gemini-3-pro', 'high');

      expect(params.containsKey('cwd'), isFalse);
      expect(params['sessionId'], 'native-1');
      expect(params['backend'], agyBackend);
      expect(params['model'], 'gemini-3-pro');
      expect(params['reasoningEffort'], 'high');
      expect(agySelectModelParams('native-1', 'gemini-3-pro', '').containsKey('reasoningEffort'), isFalse);
    });
  });
}
