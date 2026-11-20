/// Behaviour tests for the CodeX virtual archive/unarchive bridge.
///
/// The harness is exercised through its public [CodexVirtualHarness.dispatch]
/// entry point. A [CodexAppApi] double answers `thread/list`, `thread/archive`,
/// `thread/unarchive` and `turn/interrupt`; a [DshCarrier] double makes any
/// accidental physical call fail loudly. Nothing reads source text and no
/// `codex.app.call` mux/transport is needed.
library;

import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

const int _t0 = 1700000000000;

class _RecordedCall {
  _RecordedCall({required this.method, required this.params});

  final String method;
  final Map<String, Object?> params;

  @override
  String toString() => '$method($params)';
}

/// Minimal App Server double. Threads are keyed by native id; `thread/list`
/// honours the `archived` filter exactly like the real App Server does.
class _FakeCodexApi implements CodexAppApi {
  _FakeCodexApi(Map<String, bool> archivedById) {
    threads = <String, Map<String, Object?>>{
      for (final entry in archivedById.entries)
        entry.key: <String, Object?>{
          'id': entry.key,
          'name': entry.key,
          'cwd': '/work/${entry.key}',
          'createdAt': _t0,
          'updatedAt': _t0,
          'archived': entry.value,
        },
    };
  }

  late final Map<String, Map<String, Object?>> threads;

  final List<_RecordedCall> calls = <_RecordedCall>[];

  /// When set, `turn/interrupt` throws this instead of answering.
  Object? interruptError;

  @override
  bool previewHistory = false;

  @override
  Duration get callTimeout => const Duration(seconds: 1);

  @override
  Duration get transferCallTimeout => const Duration(seconds: 1);

  @override
  Future<Object?> request(String method, Map<String, Object?> params) async {
    calls.add(_RecordedCall(method: method, params: params));
    switch (method) {
      case 'project/list':
        return <String, Object?>{'data': <Object?>[]};
      case 'thread/list':
        final archived = params['archived'] == true;
        return <String, Object?>{
          'data': threads.values.where((thread) => thread['archived'] == archived).toList(),
        };
      case 'thread/archive':
      case 'thread/unarchive':
        final threadId = params['threadId'] as String;
        final thread = threads[threadId];
        if (thread == null) throw StateError('unknown thread $threadId');
        threads[threadId] = <String, Object?>{
          ...thread,
          'archived': method == 'thread/archive',
        };
        return <String, Object?>{};
      case 'turn/interrupt':
        final error = interruptError;
        if (error != null) throw error;
        return <String, Object?>{};
      default:
        throw UnimplementedError('unexpected App Server method $method');
    }
  }

  @override
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    bool transfer = false,
  }) =>
      request(method, params);

  @override
  Future<Object?> callTransferred(Uint8List encoded) =>
      throw UnimplementedError('transfers are unused by these tests');

  @override
  Future<CodexStreamHandle> subscribe(
    String threadId,
    CodexFrameHandler onFrame, {
    void Function(CodexStreamCloseReason reason)? onClose,
  }) =>
      throw UnimplementedError('streams are unused by these tests');

  @override
  Future<void> closeStream(String streamId) =>
      throw UnimplementedError('streams are unused by these tests');

  @override
  Future<void> respond(String requestHandle, CodexApprovalDecision decision) =>
      throw UnimplementedError('approvals are unused by these tests');

  @override
  Future<void> dispose() async {}

  List<_RecordedCall> methods(String method) =>
      calls.where((call) => call.method == method).toList();
}

/// A carrier that must never be touched for a virtual endpoint.
class _FakeCarrier extends DshCarrier {
  final List<String> calls = <String>[];

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    throw StateError('virtual CodeX call leaked to the physical carrier: $endpoint');
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) =>
      throw UnimplementedError('openLink is unused by these tests');

  @override
  Future<void> close() async {}
}

/// Overrides only the lazy App Server factory; every other code path is the
/// production [CodexVirtualHarness].
class _TestHarness extends CodexVirtualHarness {
  _TestHarness(this.fakeApi, this.carrier)
      : super(hostCarrier: carrier, remote: null, hostDeviceId: 'test-host');

  final CodexAppApi fakeApi;
  final _FakeCarrier carrier;

  @override
  Future<CodexAppApi> get api => Future<CodexAppApi>.value(fakeApi);

  CodexLiveFollow activeFollow(String threadId, String turnId) => CodexLiveFollow(
        sessionId: '$codexSessionPrefix$threadId',
        threadId: threadId,
        queue: CodexValueQueue<Map<String, Object?>>(),
        nextSeq: 0,
        turn: 1,
        stepOpen: true,
        requestId: null,
        activeTurnId: turnId,
      );
}

({_TestHarness harness, _FakeCodexApi api, _FakeCarrier carrier, List<Map<String, Object?>> baseline})
    _setup(Map<String, bool> archivedById) {
  final api = _FakeCodexApi(archivedById);
  final carrier = _FakeCarrier();
  final harness = _TestHarness(api, carrier);
  final baselineQueue = CodexValueQueue<Map<String, Object?>>();
  final baseline = <Map<String, Object?>>[];
  harness.workspaceStreams.add(baselineQueue);
  baselineQueue.iterate(() {}).listen(baseline.add);
  return (harness: harness, api: api, carrier: carrier, baseline: baseline);
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Map<String, Object?> _value(RpcResult result) {
  expect(result, isA<RpcOk>(), reason: result is RpcError ? result.error.toString() : 'unexpected result');
  return (result as RpcOk).value as Map<String, Object?>;
}

List<String> _archivedIds(RpcResult result) =>
    (_value(result)['archivedSessionIds'] as List<Object?>).cast<String>().toList();

void main() {
  group('CodeX virtual archive behaviour', () {
    test('archive returns the full archived set and publishes a matching baseline', () async {
      final fixture = _setup(<String, bool>{'t1': false, 't2': false, 't0': true});
      final harness = fixture.harness;
      final api = fixture.api;
      harness.live.follows.add(harness.activeFollow('t2', 'turn-9'));

      final result = await harness.dispatch(
        'workspace/archiveSession',
        <String, Object?>{
          'request': <String, Object?>{'sessionId': 'codex:t2', 'stopActivity': true},
        },
      );

      final ids = _archivedIds(result)..sort();
      expect(ids, <String>['codex:t0', 'codex:t2']);

      final interrupt = api.methods('turn/interrupt').single;
      expect(interrupt.params, <String, Object?>{'threadId': 't2', 'turnId': 'turn-9'});
      expect(api.methods('thread/archive').single.params, <String, Object?>{'threadId': 't2'});
      expect(
        api.calls.indexWhere((call) => call.method == 'turn/interrupt'),
        lessThan(api.calls.indexWhere((call) => call.method == 'thread/archive')),
      );
      expect(api.calls.where((call) => '${call.params['threadId']}'.startsWith('codex:')), isEmpty);
      expect(fixture.carrier.calls, isEmpty);

      await _pump();
      final archivedFrames = fixture.baseline.where((frame) => frame['type'] == 'archived').toList();
      expect(archivedFrames, isNotEmpty);
      expect(
        (archivedFrames.last['archivedSessionIds'] as List<Object?>).cast<String>().toList()..sort(),
        ids,
      );

    });

    test('unarchive calls the native thread and clears the archived set', () async {
      final fixture = _setup(<String, bool>{'t1': false, 't0': true});
      final harness = fixture.harness;
      final api = fixture.api;

      final result = await harness.dispatch(
        'workspace/unarchiveSession',
        <String, Object?>{
          'request': <String, Object?>{'sessionId': 'codex:t0'},
        },
      );

      expect(_archivedIds(result), isEmpty);
      expect(api.methods('thread/unarchive').single.params, <String, Object?>{'threadId': 't0'});
      expect(api.calls.where((call) => '${call.params['threadId']}'.startsWith('codex:')), isEmpty);
      expect(fixture.carrier.calls, isEmpty);

      await _pump();
      final archivedFrames = fixture.baseline.where((frame) => frame['type'] == 'archived').toList();
      expect(archivedFrames, isNotEmpty);
      expect(archivedFrames.last['archivedSessionIds'], isEmpty);

    });

    test('a rejected turn/interrupt fails the archive instead of pretending to stop', () async {
      final fixture = _setup(<String, bool>{'t1': false});
      final harness = fixture.harness;
      final api = fixture.api;
      harness.live.follows.add(harness.activeFollow('t1', 'turn-7'));
      api.interruptError = const CodexAppException('CODEX_THREAD_BUSY', 'Resource busy');

      final result = await harness.dispatch(
        'workspace/archiveSession',
        <String, Object?>{
          'request': <String, Object?>{'sessionId': 'codex:t1', 'stopActivity': true},
        },
      );

      expect(result, isA<RpcError>());
      expect((result as RpcError).error.code, 'CODEX_THREAD_BUSY');
      expect(api.methods('thread/archive'), isEmpty);
      expect(fixture.carrier.calls, isEmpty);

    });

    test('native session ids are rejected with FEATURE_NOT_SUPPORTED', () async {
      final fixture = _setup(<String, bool>{'t1': false});
      final harness = fixture.harness;

      for (final endpoint in <String>['workspace/archiveSession', 'workspace/unarchiveSession']) {
        final result = await harness.dispatch(
          endpoint,
          <String, Object?>{
            'request': <String, Object?>{'sessionId': 'native-session'},
          },
        );
        expect(result, isA<RpcError>(), reason: endpoint);
        expect((result as RpcError).error.code, 'FEATURE_NOT_SUPPORTED', reason: endpoint);
      }
      expect(fixture.carrier.calls, isEmpty);

    });
  });
}
