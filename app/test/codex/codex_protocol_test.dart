// Protocol helpers for the Codex virtual Harness. Pure values: no Host,
// no transport, no UI. These are the bits that are easy to get subtly wrong
// when porting the official virtual bundle to Dart.

import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('codexHarnessSessionGeneration', () {
    test('only 0.1.5+ and 0.2.x use the v3 event schema', () {
      expect(codexHarnessSessionGeneration('0.1.4'), 'legacy');
      expect(codexHarnessSessionGeneration('0.1.5'), 'v3');
      expect(codexHarnessSessionGeneration('0.1.9-beta.1'), 'v3');
      expect(codexHarnessSessionGeneration('0.2.0'), 'v3');
      expect(codexHarnessSessionGeneration('dsh-v0.2.3'), 'v3');
      expect(codexHarnessSessionGeneration('0.3.0'), 'legacy');
      expect(codexHarnessSessionGeneration('1.0.0'), 'legacy');
      expect(codexHarnessSessionGeneration(null), 'legacy');
      expect(codexHarnessSessionGeneration('not-a-version'), 'legacy');
    });
  });

  group('wire envelope', () {
    test('carrier args unwrap the host {args: bare} envelope', () {
      final args = codexCarrierArgs(<String, Object?>{'args': <String, Object?>{'threadId': 't1'}});
      expect(args['threadId'], 't1');
      expect(codexCarrierArgs(<String, Object?>{}), isEmpty);
    });

    test('session addresses prefer sessionId, then childSessionId', () {
      expect(
        codexSessionIdFromAddress(const <String, Object?>{'kind': 'session', 'sessionId': 'thread-1'}),
        'thread-1',
      );
      expect(
        codexSessionIdFromAddress(const <String, Object?>{'kind': 'sub', 'childSessionId': 'child-1'}),
        'child-1',
      );
    });

    test('request arg accepts both request and _request envelopes', () {
      expect(codexRequestArg(const <String, Object?>{'request': <String, Object?>{'id': 1}})['id'], 1);
      expect(codexRequestArg(const <String, Object?>{'_request': <String, Object?>{'id': 2}})['id'], 2);
    });
  });

  group('turn end', () {
    test('failed turns keep the host error info', () {
      final reason = codexTurnEndReason(const <String, Object?>{
        'status': 'failed',
        'error': <String, Object?>{
          'message': 'boom',
          'codex_error_info': 'turn_failed',
          'code': 'legacy_code',
        },
      });
      expect(reason['kind'], 'error');
      final error = reason['error'] as Map<String, Object?>;
      expect(error['message'], 'boom');
      expect(error['code'], 'turn_failed');
      expect(error['codex_error_info'], 'turn_failed');
    });

    test('cancelled aliases become interrupted, everything else completes', () {
      for (final status in ['interrupted', 'cancelled', 'canceled', 'aborted']) {
        expect(codexTurnEndReason(<String, Object?>{'status': status})['kind'], 'interrupted', reason: status);
      }
      expect(codexTurnEndReason(const <String, Object?>{'status': 'completed'})['kind'], 'completed');
      expect(codexTurnEndReason(const <String, Object?>{})['kind'], 'completed');
    });

    test('a bare error string keeps the official fallback code', () {
      final error = codexProjectTurnError('oops');
      expect(error['message'], 'oops');
      expect(error['code'], 'codex-turn-failed');
    });
  });

  group('permission preset', () {
    test('reads the flat account response', () {
      expect(
        codexPermissionPresetFromResponse(const <String, Object?>{
          'sandbox': 'danger-full-access',
          'approvalPolicy': 'never',
        }),
        'danger-full-access',
      );
      expect(
        codexPermissionPresetFromResponse(const <String, Object?>{
          'sandbox': 'workspace-write',
          'approvalPolicy': 'on-request',
        }),
        'workspace-write',
      );
    });

    test('reads threadSettings object sandboxes and rejects mismatches', () {
      expect(
        codexPermissionPresetFromResponse(const <String, Object?>{
          'threadSettings': <String, Object?>{
            'sandbox': <String, Object?>{'type': 'workspaceWrite'},
            'approvalPolicy': 'on-request',
          },
        }),
        'workspace-write',
      );
      expect(
        codexPermissionPresetFromResponse(const <String, Object?>{
          'sandbox': 'danger-full-access',
          'approvalPolicy': 'on-request',
        }),
        isNull,
      );
    });
  });
}
