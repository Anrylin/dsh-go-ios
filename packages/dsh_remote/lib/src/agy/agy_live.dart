/// Live AGY turn projection: translates `agent.acp.frame` session updates into
/// the existing DSH v3 `session/follow` stream consumed by the native Chat UI.
library;

import 'dart:async';
import 'dart:convert';

import '../util/bytes.dart';
import 'agy_api.dart';
import 'agy_catalog.dart';
import 'agy_contract.dart';
import 'agy_history.dart';
import 'agy_values.dart';

abstract interface class AgyLiveContext {
  bool get closed;

  AgySession? sessionById(String sessionId);

  Future<void> hydrate(AgySession session);

  Future<JsonMap> readHistoryPage(AgySession session, JsonMap request);

  Future<AgyStreamHandle> openSessionStream(
    String nativeSessionId, {
    required void Function(JsonMap frame) onFrame,
    required void Function(String reason) onClosed,
  });

  void invalidateHistory(String sessionId);

  void updateTitle(String sessionId, String title);

  void setModelSelection(String sessionId, JsonMap selected);

  void setPermissionPreset(String sessionId, String preset);

  int nextProjectionSeq();

  void publishProjection(String sessionId, String key, Object? value, int seq);

  void emitRemoteEvent(String type, List<Object?> payload);

  void emitApproval(String eventId, String requestHandle, JsonMap request, {String? sessionId});
}

class AgyStreamBlock {
  AgyStreamBlock({required this.index, required this.kind, this.text = ''});

  final int index;
  final String kind;
  String text;
}

class AgyToolCall {
  AgyToolCall({required this.callId, required this.name, this.arguments});

  final String callId;
  final String name;
  final Object? arguments;
}

class AgyAssistantAttempt {
  AgyAssistantAttempt({
    required this.attemptId,
    required this.startedAfterSeq,
    required this.turn,
  }) : stream = <Object?>[];

  final String attemptId;
  final int startedAfterSeq;
  final int turn;
  final List<Object?> stream;
  int nextIndex = 0;
  int revision = 0;
}

class AgyLiveFollow {
  AgyLiveFollow({
    required this.sessionId,
    required this.nativeId,
    required this.queue,
    required this.nextSeq,
    required this.turn,
    required this.stepOpen,
    this.activeTurnId,
  });

  final String sessionId;
  final String nativeId;
  final AgyValueQueue<JsonMap> queue;
  int nextSeq;
  int turn;
  bool stepOpen;
  String? activeTurnId;

  final List<AgyStreamBlock> blocks = <AgyStreamBlock>[];
  AgyAssistantAttempt? assistantAttempt;
  final Map<String, AgyToolCall> tools = <String, AgyToolCall>{};
  final Set<String> completedTools = <String>{};
  bool sawLiveContent = false;
  int assistantStreamRevision = 0;
  Future<void> Function()? close;
}

class AgyLiveProjection {
  AgyLiveProjection(this.context);

  final AgyLiveContext context;
  final Set<AgyLiveFollow> follows = <AgyLiveFollow>{};

  bool get isEmpty => follows.isEmpty;

  AgyLiveFollow? followFor(String sessionId) {
    for (final follow in follows) {
      if (follow.sessionId == sessionId) return follow;
    }
    return null;
  }

  /// The full `session/follow` stream: history snapshot first, live frames
  /// immediately afterwards. The ACP stream is armed before the snapshot is
  /// pushed, so no frame emitted between subscription and history is lost.
  Stream<JsonMap> sessionFollow(JsonMap request) async* {
    final sessionId = agyExtractSessionId(request);
    final session = context.sessionById(sessionId);
    if (session == null) {
      throw AgyFailure('session-not-found', 'The ACP session is not registered.');
    }
    await context.hydrate(session);
    final page = await context.readHistoryPage(session, <String, Object?>{
      if (agyPositiveInt(request['maxMessages']) case final int maxMessages?) 'maxMessages': maxMessages,
      if (agyInt(request['throughSeq']) case final int throughSeq?) 'throughSeq': throughSeq,
      if (agyInt(request['beforeSeq']) case final int beforeSeq?) 'beforeSeq': beforeSeq,
    });

    final cursor = agyInt(page['cursor']) ?? -1;
    final queue = AgyValueQueue<JsonMap>();
    final follow = AgyLiveFollow(
      sessionId: sessionId,
      nativeId: session.nativeId,
      queue: queue,
      nextSeq: cursor + 1,
      turn: (agyInt(page['turn']) ?? 1) < 1 ? 1 : agyInt(page['turn']) ?? 1,
      stepOpen: page['activeTurnId'] != null,
      activeTurnId: agyString(page['activeTurnId']),
    );
    await _arm(follow);
    follows.add(follow);
    queue.push(agyHistorySnapshot(session, page));
    context.emitRemoteEvent('api-session/status', <Object?>[sessionId, session.running]);
    yield* queue.iterate(() => _dispose(follow));
  }

  /// Used before `session/prompt`: opens the live stream without duplicating a
  /// follow if the UI is already attached to this session.
  Future<AgyLiveFollow> ensureFollow(AgySession session) async {
    final existing = followFor(session.id);
    if (existing != null) return existing;
    final queue = AgyValueQueue<JsonMap>();
    final follow = AgyLiveFollow(
      sessionId: session.id,
      nativeId: session.nativeId,
      queue: queue,
      nextSeq: 0,
      turn: 1,
      stepOpen: false,
    );
    await _arm(follow);
    follows.add(follow);
    unawaited(queue.iterate(() => _dispose(follow)).drain<void>().catchError((Object _) {}));
    return follow;
  }

  Future<void> _arm(AgyLiveFollow follow) async {
    try {
      final handle = await context.openSessionStream(
        follow.nativeId,
        onFrame: (frame) => acceptAcpFrame(follow, frame),
        onClosed: (reason) => closeFollowAfterRemoteStreamClosed(follow),
      );
      follow.close = handle.close;
      if (context.closed) {
        await handle.close();
        throw AgyFailure('closed', 'The AGY virtual Harness is closed.');
      }
    } on Object {
      follows.remove(follow);
      follow.queue.close();
      rethrow;
    }
  }

  void _dispose(AgyLiveFollow follow) {
    follows.remove(follow);
    final close = follow.close;
    if (close != null) unawaited(close());
  }

  /// Local events synthesized by the virtual Harness for a prompt submission.
  void beginPrompt(AgySession session, String text) {
    final follow = followFor(session.id);
    if (follow == null) return;
    if (follow.stepOpen) finishTurn(follow, const <String, Object?>{'kind': 'abandoned'}, publish: false);
    _resetLiveTurn(follow);
    follow.turn += 1;
    follow.stepOpen = true;
    pushEvent(follow, 'turn/start', <String, Object?>{'turn': follow.turn});
    pushEvent(follow, 'step/start', <String, Object?>{'turn': follow.turn, 'step': 1});
    if (text.isNotEmpty) {
      pushEvent(follow, 'user/message', <String, Object?>{
        'turn': follow.turn,
        'step': 1,
        'message': <String, Object?>{
          'id': 'user:${DateTime.now().millisecondsSinceEpoch}',
          'role': 'user',
          'content': <Object?>[<String, Object?>{'type': 'text', 'text': text}],
        },
      });
    }
    context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, true]);
    context.emitRemoteEvent('api-session/activity', <Object?>[follow.sessionId, DateTime.now().millisecondsSinceEpoch]);
  }

  void abortTurn(String sessionId, {String kind = 'user'}) {
    for (final follow in follows.where((item) => item.sessionId == sessionId).toList(growable: false)) {
      finishTurn(follow, <String, Object?>{'kind': kind});
    }
  }

  void acceptAcpFrame(AgyLiveFollow follow, JsonMap frame) {
    final method = agyString(frame['method']);
    final params = agyMap(frame['params']);
    if (method == null || context.closed) return;

    if (method == 'session/update') {
      final update = agyMap(params['update'])..putIfAbsent('sessionUpdate', () => agyString(frame['sessionUpdate']));
      acceptSessionUpdate(follow, update);
      return;
    }
    if (method == 'session/request_permission') {
      final handle = agyString(params['requestHandle']);
      if (handle == null) return;
      context.emitApproval(handle, handle, params, sessionId: follow.sessionId);
      return;
    }
    if (method == 'prompt_completed' || method == 'prompt_failed') {
      _finishWithCatchUp(follow, method, params);
    }
  }

  void acceptSessionUpdate(AgyLiveFollow follow, JsonMap update) {
    final variant = agyString(update['sessionUpdate']);
    if (variant == null) return;

    if (variant == 'session_info_update') {
      final title = agyString(update['title']) ?? agyString(update['name']);
      if (title != null && title.trim().isNotEmpty) {
        context.updateTitle(follow.sessionId, title.length > 256 ? title.substring(0, 256) : title);
      }
      return;
    }
    if (variant == 'model_selection') {
      final selected = agyMap(update['selected']);
      if (agyString(selected['provider']) != agyBackend) return;
      context.setModelSelection(follow.sessionId, selected);
      return;
    }
    if (variant == 'agent_message_chunk' || variant == 'agent_message') {
      final text = agyString(update['text']);
      if (text == null || text.isEmpty) return;
      follow.sawLiveContent = true;
      _appendDelta(follow, variant == 'agent_message' ? 'message' : 'text', text);
      return;
    }
    if (variant == 'agent_thought_chunk' || variant == 'agent_thought') {
      final text = agyString(update['text']);
      if (text == null || text.isEmpty) return;
      follow.sawLiveContent = true;
      _appendDelta(follow, variant == 'agent_thought' ? 'reasoning' : 'thought', text);
      return;
    }
    if (variant == 'user_message_chunk') {
      final text = agyString(update['text']) ?? '';
      pushEvent(follow, 'user/message', <String, Object?>{
        'turn': follow.turn,
        'step': 1,
        'message': <String, Object?>{
          'id': 'user:${DateTime.now().millisecondsSinceEpoch}',
          'role': 'user',
          'content': <Object?>[<String, Object?>{'type': 'text', 'text': text}],
        },
      });
      return;
    }
    if (variant == 'tool_call') {
      final callId = agyString(update['callId']) ?? 'tool:${follow.nextSeq}';
      final name = agyString(update['name']) ?? agyString(update['toolName']) ?? 'tool';
      final call = AgyToolCall(callId: callId, name: name, arguments: update['parameters'] ?? update['args']);
      follow.tools[callId] = call;
      follow.sawLiveContent = true;
      _ensureTurn(follow);
      final arguments = _jsonString(call.arguments);
      pushEvent(
        follow,
        'tool/call',
        <String, Object?>{
          'turn': follow.turn,
          'step': 1,
          'callId': callId,
          'name': name,
          'arguments': arguments,
        },
        <String, Object?>{'for': 'call', 'view': <String, Object?>{
          'callId': callId,
          'name': name,
          'arguments': arguments,
        }},
      );
      return;
    }
    if (variant == 'tool_call_update') {
      final callId = agyString(update['callId']);
      if (callId == null || follow.completedTools.contains(callId)) return;
      follow.completedTools.add(callId);
      final call = follow.tools[callId] ?? AgyToolCall(callId: callId, name: 'tool');
      final status = agyString(update['status']) ?? 'completed';
      final output = _toolOutput(update['output']);
      final failed = status == 'failed';
      follow.sawLiveContent = true;
      pushEvent(
        follow,
        'tool/result',
        <String, Object?>{
          'turn': follow.turn,
          'step': 1,
          'message': <String, Object?>{
            'id': '$callId:result',
            'role': 'user',
            'content': <Object?>[
              <String, Object?>{
                'type': 'tool-result',
                'toolCallId': callId,
                'content': <Object?>[<String, Object?>{'type': 'text', 'text': output}],
                if (failed) 'isError': true,
              },
            ],
            'source': <String, Object?>{'kind': 'tool', 'callId': callId},
          },
        },
        <String, Object?>{'for': 'result', 'view': <String, Object?>{
          'callId': callId,
          'name': call.name,
          'output': output,
          'status': status,
        }},
      );
      return;
    }
    if (variant == 'prompt_completed' || variant == 'prompt_failed') {
      _finishWithCatchUp(follow, variant, update);
    }
  }

  void _finishWithCatchUp(AgyLiveFollow follow, String variant, JsonMap params) {
    final catchUp = agyList(params['catchUp']);
    if (!follow.sawLiveContent && catchUp.isNotEmpty) {
      for (final value in catchUp) {
        final update = agyMap(value);
        if (!_isCatchUpVariant(agyString(update['sessionUpdate']))) continue;
        acceptSessionUpdate(follow, update);
      }
    }
    finishTurn(
      follow,
      variant == 'prompt_failed'
          ? <String, Object?>{'kind': 'error', 'code': agyString(params['code']) ?? 'ACP_PROMPT_FAILED'}
          : <String, Object?>{'kind': 'stop', 'stopReason': agyString(params['stopReason']) ?? 'end_turn'},
    );
  }

  static bool _isCatchUpVariant(String? variant) => switch (variant) {
        'agent_message_chunk' ||
        'agent_message' ||
        'agent_thought_chunk' ||
        'agent_thought' ||
        'user_message_chunk' ||
        'tool_call' ||
        'tool_call_update' =>
          true,
        _ => false,
      };

  void _ensureTurn(AgyLiveFollow follow) {
    if (follow.stepOpen) return;
    follow.stepOpen = true;
    pushEvent(follow, 'turn/start', <String, Object?>{'turn': follow.turn});
    pushEvent(follow, 'step/start', <String, Object?>{'turn': follow.turn, 'step': 1});
    context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, true]);
  }

  void _appendDelta(AgyLiveFollow follow, String kind, String delta) {
    _ensureTurn(follow);
    AgyStreamBlock block;
    if (follow.blocks.isNotEmpty && follow.blocks.last.kind == kind) {
      block = follow.blocks.last;
    } else {
      block = AgyStreamBlock(index: follow.blocks.length, kind: kind);
      follow.blocks.add(block);
      pushAssistantChunk(follow, <String, Object?>{'type': 'block-start', 'index': block.index, 'blockType': kind});
    }
    block.text = _appendBoundedText(block.text, delta);
    pushAssistantChunk(follow, <String, Object?>{
      'type': kind == 'reasoning' ? 'reasoning-delta' : 'text-delta',
      'index': block.index,
      'text': delta,
    });
  }

  String _appendBoundedText(String current, String delta) {
    const max = maxAcpUpdateBytes;
    final next = current + delta;
    if (next.length <= max) return next;
    final bytes = utf8.encode(next);
    if (bytes.length <= max) return next;
    final kept = utf8.decode(bytes.sublist(bytes.length - max), allowMalformed: true);
    return kept;
  }

  void pushAssistantChunk(AgyLiveFollow follow, JsonMap chunk) {
    var attempt = follow.assistantAttempt;
    if (attempt == null) {
      attempt = AgyAssistantAttempt(
        attemptId: 'acp-attempt:${follow.sessionId}:${follow.nextSeq}',
        startedAfterSeq: follow.nextSeq - 1,
        turn: follow.turn,
      );
      follow.assistantAttempt = attempt;
      follow.assistantStreamRevision += 1;
      follow.queue.push(<String, Object?>{
        'type': 'assistant-stream',
        'frame': <String, Object?>{
          'type': 'start',
          'attemptId': attempt.attemptId,
          'revision': follow.assistantStreamRevision,
          'startedAfterSeq': attempt.startedAfterSeq,
          'turn': follow.turn,
          'step': 1,
        },
      });
    }
    final time = DateTime.now().millisecondsSinceEpoch;
    final index = attempt.nextIndex++;
    attempt.stream.add(<String, Object?>{'time': time, 'chunk': chunk});
    follow.assistantStreamRevision += 1;
    follow.queue.push(<String, Object?>{
      'type': 'assistant-stream',
      'frame': <String, Object?>{
        'type': 'chunk',
        'attemptId': attempt.attemptId,
        'revision': follow.assistantStreamRevision,
        'index': index,
        'time': time,
        'chunk': chunk,
      },
    });
  }

  void finishTurn(AgyLiveFollow follow, JsonMap outcome, {bool publish = true}) {
    final committed = follow.blocks
        .map((block) => <String, Object?>{
              'type': switch (block.kind) {
                'thought' || 'reasoning' => 'thinking',
                _ => 'text',
              },
              'text': block.text,
            })
        .toList(growable: false);
    for (final block in follow.blocks) {
      pushAssistantChunk(follow, <String, Object?>{
        'type': 'block-end',
        'index': block.index,
        'block': <String, Object?>{'type': block.kind, 'text': block.text},
      });
    }
    follow.blocks.clear();
    pushAssistantChunk(follow, <String, Object?>{
      'type': 'finish',
      'reason': <String, Object?>{'kind': agyString(outcome['kind']) ?? 'stop'},
    });

    final attempt = follow.assistantAttempt;
    if (attempt != null) {
      final assistantText = committed.fold<String>('', (previous, block) => '$previous${agyString(block['text']) ?? ''}');
      if (assistantText.isNotEmpty) {
        pushEvent(follow, 'assistant/message', <String, Object?>{
          'turn': attempt.turn,
          'step': 1,
          'message': <String, Object?>{
            'id': 'assistant:${attempt.attemptId}',
            'role': 'assistant',
            'content': <Object?>{
              ...committed,
              if (committed.isEmpty) <String, Object?>{'type': 'text', 'text': assistantText},
            }.toList(),
            'source': <String, Object?>{'kind': 'acp', 'sessionId': follow.sessionId},
            'stream': attempt.stream,
          },
        });
      }
      follow.assistantAttempt = null;
      follow.assistantStreamRevision += 1;
      follow.queue.push(<String, Object?>{
        'type': 'assistant-stream',
        'frame': <String, Object?>{
          'type': 'end',
          'attemptId': attempt.attemptId,
          'revision': follow.assistantStreamRevision,
          'index': attempt.nextIndex,
          'outcome': outcome,
        },
      });
    }

    if (follow.stepOpen) {
      pushEvent(follow, 'step/end', <String, Object?>{'turn': follow.turn, 'step': 1});
      follow.stepOpen = false;
    }
    pushEvent(follow, 'turn/end', <String, Object?>{'turn': follow.turn, 'reason': outcome});
    if (publish) {
      context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, false]);
      context.emitRemoteEvent('api-session/activity', <Object?>[follow.sessionId, DateTime.now().millisecondsSinceEpoch]);
    }
    follow.activeTurnId = null;
    context.invalidateHistory(follow.sessionId);
  }

  int pushEvent(
    AgyLiveFollow follow,
    String type,
    JsonMap data, [
    JsonMap? view,
  ]) {
    final seq = follow.nextSeq++;
    final event = <String, Object?>{
      'type': type,
      'seq': seq,
      'time': DateTime.now().millisecondsSinceEpoch,
      'data': data,
      if (agyIsSurfaceEvent(type)) 'surfaceOp': 'append',
    };
    follow.queue.push(<String, Object?>{
      'type': 'event',
      'event': event,
      if (view != null) 'view': view,
    });
    return seq;
  }

  void _resetLiveTurn(AgyLiveFollow follow) {
    follow.blocks.clear();
    follow.assistantAttempt = null;
    follow.tools.clear();
    follow.completedTools.clear();
    follow.sawLiveContent = false;
  }

  void closeFollowAfterRemoteStreamClosed(AgyLiveFollow follow) {
    if (follows.remove(follow)) {
      follow.queue.close();
      context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, false]);
    }
  }

  void invalidateAll() {
    for (final follow in follows) {
      context.invalidateHistory(follow.sessionId);
    }
  }

  void close() {
    for (final follow in follows.toList(growable: false)) {
      follows.remove(follow);
      follow.queue.close();
      final close = follow.close;
      if (close != null) unawaited(close());
    }
  }
}

String _jsonString(Object? value) {
  if (value == null) return '{}';
  if (value is String) return value;
  return jsonEncode(value);
}

String _toolOutput(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return jsonEncode(value);
}
