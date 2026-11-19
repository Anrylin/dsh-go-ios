/// Live Codex turn projection: translates the official client's
/// `dist/codex/virtual-live.js` (509 lines) into Dart. It consumes decoded
/// `codex.app.frame` events from [CodexAppApi.subscribe], maintains a
/// contiguous, revision-stable event sequence and emits the same DSH
/// `session/follow` frames as the bundled virtual Harness.
library;

import 'dart:async';

import '../util/bytes.dart';
import 'codex_api.dart';
import 'codex_catalog.dart';
import 'codex_contract.dart';
import 'codex_history.dart';
import 'codex_image_codec.dart';
import 'codex_permissions.dart';
import 'codex_turn_end.dart';
import 'codex_values.dart';

abstract interface class CodexLiveContext {
  bool get closed;
  String get sessionGeneration;
  Map<String, Object?> get pendingRequestIds;
  Map<String, Object?> get pendingApprovals;
  Map<String, Object?> get imageAttachments;
  Map<String, Object?> get selectedModels;

  Future<Map<String, Object?>> readHistoryPage(String threadId, Map<String, Object?> request);
  Future<CodexModelDirectory?> models();
  Future<void> refreshAndPublishWorkspaces({bool force = false});
  Future<CodexStreamHandle> subscribe(
    String threadId,
    void Function(Map<String, Object?> frame) onFrame,
  );

  String? sessionTitle(String sessionId);
  Map<String, Object?> modelSelection(String sessionId, [CodexModelDirectory? directory]);
  String? permissionSelection(String sessionId);
  void setPermissionSelection(String sessionId, String? preset);
  int nextProjectionSeq();
  void publishProjection(String sessionId, String key, Object? value, int seq);
  void emitRemoteEvent(String type, List<Object?> payload);
  void emitApproval(Map<String, Object?> event);
  void invalidateThreadHistory(String threadId);
  void updateThreadName(String threadId, String name);
  void rememberOpenedSession(String sessionId);
}

class CodexStreamBlock {
  const CodexStreamBlock({
    required this.itemId,
    required this.index,
    required this.kind,
    required this.text,
  });

  final String itemId;
  final int index;
  final String kind;
  final String text;

  CodexStreamBlock copyWith({String? text}) => CodexStreamBlock(
        itemId: itemId,
        index: index,
        kind: kind,
        text: text ?? this.text,
      );
}

class CodexAssistantAttempt {
  CodexAssistantAttempt({
    required this.attemptId,
    required this.startedAfterSeq,
    required this.nextIndex,
    required List<Object?> stream,
  }) : stream = List<Object?>.from(stream);

  final String attemptId;
  final int startedAfterSeq;
  int nextIndex;
  final List<Object?> stream;
}

class CodexLiveFollow {
  CodexLiveFollow({
    required this.sessionId,
    required this.threadId,
    required this.queue,
    required this.nextSeq,
    required this.turn,
    required this.stepOpen,
    required this.requestId,
    this.activeTurnId,
  });

  final String sessionId;
  final String threadId;
  final CodexValueQueue<Map<String, Object?>> queue;
  int nextSeq;
  int turn;
  bool stepOpen;
  Object? requestId;
  String? activeTurnId;

  final Set<Object?> startedItems = <Object?>{};
  final Set<Object?> completedItems = <Object?>{};
  final Map<String, CodexStreamBlock> streamedBlocks = <String, CodexStreamBlock>{};
  int nextBlockIndex = 0;
  bool streamActive = false;
  int assistantStreamRevision = 0;
  CodexAssistantAttempt? assistantAttempt;
  final Map<String, JsonMap> liveItems = <String, JsonMap>{};
  final Map<String, String> liveToolOutput = <String, String>{};
  final Map<String, int> liveToolResultSeq = <String, int>{};
  final List<Object?> pendingToolImages = <Object?>[];
  Future<void> Function()? close;
}

class CodexLiveProjection {
  CodexLiveProjection(this.context);

  final CodexLiveContext context;
  final Set<CodexLiveFollow> follows = <CodexLiveFollow>{};

  Stream<Map<String, Object?>> sessionFollow(Map<String, Object?> request) async* {
    final sessionId = codexSessionIdFromAddress(codexRecord(request['address']));
    final threadId = codexNativeThreadId(sessionId);
    final historyFuture = context.readHistoryPage(threadId, <String, Object?>{
      if (codexFiniteNumber(request['maxMessages']) != null)
        'maxMessages': codexFiniteNumber(request['maxMessages'])!.toInt(),
    });
    final modelsFuture = context.models().then<CodexModelDirectory?>(
      (directory) => directory,
      onError: (Object _) => null,
    );
    final results = await Future.wait<Object?>([historyFuture, modelsFuture]);
    final history = results[0] as Map<String, Object?>;
    final directory = results[1] as CodexModelDirectory?;
    final cursor = codexInteger(history['cursor']) ?? -1;
    final header = codexRecord(history['header']);
    final records = codexArray(history['records']);
    final nextTurn = codexInteger(history['nextTurn']) ?? 1;
    final activeTurnId = codexString(history['activeTurnId']);

    final queue = CodexValueQueue<Map<String, Object?>>();
    final follow = CodexLiveFollow(
      sessionId: sessionId,
      threadId: threadId,
      queue: queue,
      nextSeq: cursor + 1,
      turn: nextTurn,
      stepOpen: activeTurnId != null,
      requestId: context.pendingRequestIds[sessionId],
      activeTurnId: activeTurnId,
    );
    follows.add(follow);
    final selection = context.modelSelection(sessionId, directory);
    final title = context.sessionTitle(sessionId);
    final permission = context.permissionSelection(sessionId);
    queue.push(<String, Object?>{
      'type': 'snapshot',
      'header': header,
      'cursor': cursor,
      'records': records,
      'hasMore': history['hasMore'] == true,
      'projections': <String, Object?>{
        'asOfSeq': cursor,
        'values': <String, Object?>{
          'title': title,
          'sessionListMetadata': <String, Object?>{'blank': cursor < 0, 'lastPromptAt': null},
          'modelSelection': codexModelSelectionProjection(selection),
          'permissions': codexPermissionsProjection(permission),
          'imageLimits': codexImageLimitsProjection(),
        },
      },
      if (context.sessionGeneration == 'v3')
        'assistantStream': <String, Object?>{'revision': 0},
    });

    CodexStreamHandle? stream;
    try {
      stream = await context.subscribe(threadId, (frame) => acceptCodexFrame(follow, frame));
      if (context.closed) {
        await stream.close();
        throw CodexValueError('The CodeX virtual Harness is closed.');
      }
      follow.close = stream.close;
      unawaited(context.refreshAndPublishWorkspaces());
    } on Object {
      follows.remove(follow);
      queue.close();
      rethrow;
    }
    context.rememberOpenedSession(sessionId);
    yield* queue.iterate(() {
      follows.remove(follow);
      final close = follow.close;
      if (close != null) unawaited(close());
    });
  }

  void acceptCodexFrame(CodexLiveFollow follow, Map<String, Object?> frame) {
    final method = codexString(frame['method']);
    final params = codexRecord(frame['params']);
    if (method == null) return;

    if (method == 'thread/name/updated') {
      final name = codexString(params['threadName']);
      if (name == null) return;
      final seq = context.nextProjectionSeq();
      context.updateThreadName(follow.threadId, name);
      final title = name.trim().isEmpty ? null : (name.length > 256 ? name.substring(0, 256) : name);
      context.publishProjection(follow.sessionId, 'title', title, seq);
      return;
    }
    if (method == 'thread/settings/updated') {
      context.setPermissionSelection(follow.sessionId, codexPermissionPresetFromResponse(params));
      return;
    }
    context.invalidateThreadHistory(follow.threadId);

    if (method == 'turn/started') {
      final turn = codexRecord(params['turn']);
      final projected = _projectCodexModel(turn);
      final model = codexString(projected['model']);
      if (model != null) {
        final selected = <String, Object?>{
          'provider': codexProvider,
          'model': model,
          if (projected['reasoningEffort'] != null) 'reasoningEffort': projected['reasoningEffort'],
        };
        context.selectedModels[follow.sessionId] = selected;
        context.publishProjection(
          follow.sessionId,
          'modelSelection',
          codexModelSelectionProjection(selected),
          context.nextProjectionSeq(),
        );
      }
      endAssistantAttempt(follow, const <String, Object?>{'kind': 'abandoned'});
      resetLiveTurn(follow);
      follow.turn += 1;
      follow.activeTurnId = codexString(turn['id']);
      follow.requestId = context.pendingRequestIds[follow.sessionId];
      follow.stepOpen = true;
      pushEvent(follow, 'turn/start', <String, Object?>{'turn': follow.turn});
      pushEvent(follow, 'step/start', <String, Object?>{'turn': follow.turn, 'step': 1});
      context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, true]);
      for (final item in codexArray(turn['items'])) {
        acceptCompletedItem(follow, codexRecord(item), false);
      }
      return;
    }

    if (method == 'item/started' || method == 'item/completed') {
      final item = codexRecord(params['item']);
      final itemId = codexString(item['id']);
      if (method == 'item/started' && itemId != null) {
        follow.startedItems.add(itemId);
        follow.liveItems[itemId] = item;
        final type = codexString(item['type']);
        if (codexIsToolItemType(type)) ensureToolStarted(follow, item);
      }
      if (method == 'item/completed') acceptCompletedItem(follow, item, true);
      return;
    }

    if (method == 'item/agentMessage/delta') {
      final itemId = codexString(params['itemId']) ?? 'assistant:${follow.turn}';
      final delta = codexString(params['delta']);
      if (delta == null) return;
      appendStreamDelta(follow, 'agent:$itemId', itemId, 'text', delta);
      return;
    }

    if (method == 'item/reasoning/summaryPartAdded') {
      final itemId = codexString(params['itemId']);
      if (itemId != null) {
        ensureStreamBlock(
          follow,
          'reasoning-summary:$itemId:${codexInteger(params['summaryIndex']) ?? 0}',
          itemId,
          'reasoning',
        );
      }
      return;
    }

    if (method == 'item/reasoning/summaryTextDelta' ||
        method == 'item/reasoning/textDelta' ||
        method == 'item/plan/delta') {
      final itemId = codexString(params['itemId']);
      final delta = codexString(params['delta']);
      if (itemId == null || delta == null) return;
      final key = switch (method) {
        'item/plan/delta' => 'plan:$itemId',
        'item/reasoning/summaryTextDelta' => 'reasoning-summary:$itemId:${codexInteger(params['summaryIndex']) ?? 0}',
        _ => 'reasoning-content:$itemId:${codexInteger(params['contentIndex']) ?? 0}',
      };
      appendStreamDelta(follow, key, itemId, 'reasoning', delta);
      return;
    }

    if (method == 'turn/plan/updated') {
      final todos = <Object?>[];
      for (final value in codexArray(params['plan'])) {
        final item = codexRecord(value);
        final content = codexString(item['step']);
        if (content == null) continue;
        final status = switch (item['status']) {
          'inProgress' => 'in_progress',
          'completed' => 'completed',
          _ => 'pending',
        };
        todos.add(<String, Object?>{'content': content, 'status': status});
      }
      pushEvent(follow, 'todo/write', <String, Object?>{'todos': todos});
      return;
    }

    if (method == 'item/commandExecution/outputDelta' ||
        method == 'item/fileChange/outputDelta' ||
        method == 'item/mcpToolCall/progress') {
      final itemId = codexString(params['itemId']);
      if (itemId == null) return;
      final delta = codexString(method == 'item/mcpToolCall/progress' ? params['message'] : params['delta']);
      if (delta == null) return;
      final type = switch (method) {
        'item/commandExecution/outputDelta' => 'commandExecution',
        'item/fileChange/outputDelta' => 'fileChange',
        _ => 'mcpToolCall',
      };
      final item = follow.liveItems[itemId] ?? <String, Object?>{
        'id': itemId,
        'type': type,
        'status': 'inProgress',
      };
      follow.liveItems[itemId] = item;
      ensureToolStarted(follow, item);
      final separator = method == 'item/mcpToolCall/progress' && follow.liveToolOutput.containsKey(itemId) ? '\n' : '';
      final output = codexAppendBoundedText(follow.liveToolOutput[itemId] ?? '', '$separator$delta');
      follow.liveToolOutput[itemId] = output;
      emitToolResult(follow, item, output);
      return;
    }

    if (method == 'item/fileChange/patchUpdated') {
      final itemId = codexString(params['itemId']);
      if (itemId == null) return;
      final previous = follow.liveItems[itemId] ??
          <String, Object?>{'id': itemId, 'type': 'fileChange', 'status': 'inProgress'};
      final item = Map<String, Object?>.from(previous)
        ..['changes'] = codexSanitizedFileChanges(params['changes']);
      follow.liveItems[itemId] = item;
      ensureToolStarted(follow, item);
      emitToolResult(follow, item, codexFileChangeSummary(item['changes']));
      return;
    }

    if (method == 'thread/status/changed') {
      final status = codexRecord(params['status']);
      final running = status['type'] == 'active';
      context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, running]);
      return;
    }

    if (method == 'model/rerouted') {
      final model = codexString(params['toModel']);
      if (model == null) return;
      final previous = codexRecord(context.selectedModels[follow.sessionId]);
      final selected = <String, Object?>{
        'provider': codexProvider,
        'model': model,
        if (previous['reasoningEffort'] != null) 'reasoningEffort': previous['reasoningEffort'],
      };
      context.selectedModels[follow.sessionId] = selected;
      final seq = pushEvent(follow, 'request/context', <String, Object?>{
        'provider': codexProvider,
        'model': model,
      });
      context.publishProjection(
        follow.sessionId,
        'modelSelection',
        codexModelSelectionProjection(selected),
        seq,
      );
      return;
    }

    if (method == 'turn/completed') {
      final turn = codexRecord(params['turn']);
      for (final item in codexArray(turn['items'])) {
        acceptCompletedItem(follow, codexRecord(item), true);
      }
      if (follow.stepOpen) {
        closeAllStreamBlocks(follow);
        if (follow.streamActive) finishStream(follow);
        endAssistantAttempt(follow, const <String, Object?>{'kind': 'abandoned'});
        pushEvent(follow, 'step/end', <String, Object?>{'turn': follow.turn, 'step': 1});
        follow.stepOpen = false;
      }
      pushEvent(follow, 'turn/end', <String, Object?>{
        'turn': follow.turn,
        'reason': codexTurnEndReason(turn),
      });
      context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, false]);
      context.emitRemoteEvent('api-session/activity', <Object?>[follow.sessionId, DateTime.now().millisecondsSinceEpoch]);
      follow.activeTurnId = null;
      context.pendingRequestIds.remove(follow.sessionId);
      unawaited(context.refreshAndPublishWorkspaces(force: true));
      return;
    }

    if (method == 'item/commandExecution/requestApproval' ||
        method == 'item/fileChange/requestApproval') {
      final requestHandle = codexString(params['requestHandle']);
      if (requestHandle == null) return;
      final command = codexCommandText(params['command']);
      context.pendingApprovals[requestHandle] = <String, Object?>{
        'requestHandle': requestHandle,
        'sessionId': follow.sessionId,
      };
      context.emitApproval(<String, Object?>{
        'eventId': requestHandle,
        'agentId': follow.sessionId,
        'request': <String, Object?>{
          'toolName': method.contains('fileChange') ? 'CodeX file change' : 'CodeX command',
          if (command != null) 'reason': command,
        },
      });
    }
  }

  void acceptCompletedItem(
    CodexLiveFollow follow,
    Map<String, Object?> item,
    bool settleAssistant,
  ) {
    final itemId = codexString(item['id']) ?? 'item:${follow.nextSeq}';
    if (follow.completedItems.contains(itemId)) return;
    final type = codexString(item['type']);
    if (type == 'agentMessage' && !settleAssistant) return;
    follow.completedItems.add(itemId);
    closeItemStreamBlocks(follow, itemId, codexItemText(item));
    if (type == 'agentMessage' && follow.streamActive && follow.streamedBlocks.isEmpty) {
      finishStream(follow);
    }
    final supplementalImages = type == 'agentMessage' ? follow.pendingToolImages : const <Object?>[];
    int? assistantMessageSeq;
    for (final event in codexItemEvents(
      item,
      follow.turn,
      1,
      follow.requestId,
      context.modelSelection(follow.sessionId),
      follow.sessionId,
      supplementalImages,
    )) {
      final eventType = codexString(event['type']);
      if (eventType == null) continue;
      final data = codexRecord(event['data']);
      final view = event['view'];
      if (eventType == 'tool/call' && follow.startedItems.contains(itemId)) continue;
      if (eventType == 'tool/result') {
        pushToolResult(follow, itemId, event);
      } else {
        final seq = pushEvent(follow, eventType, data, view is Map ? Map<String, Object?>.from(view) : null);
        if (eventType == 'assistant/message') assistantMessageSeq = seq;
      }
    }
    if (type == 'agentMessage' && assistantMessageSeq != null) {
      endAssistantAttempt(follow, <String, Object?>{
        'kind': 'committed',
        'eventType': 'assistant/message',
        'seq': assistantMessageSeq,
      });
    }
    if (type == 'agentMessage' && supplementalImages.isNotEmpty) {
      follow.pendingToolImages.clear();
    } else if (type != null && codexIsToolItemType(type)) {
      follow.pendingToolImages.addAll(codexToolOutputImageBlocks(item));
    }
    follow.liveItems.remove(itemId);
    follow.liveToolOutput.remove(itemId);
    follow.liveToolResultSeq.remove(itemId);
    follow.liveToolResultSeq.remove('$itemId:call');
  }

  int pushEvent(
    CodexLiveFollow follow,
    String type,
    Map<String, Object?> data, [
    Map<String, Object?>? view,
    ({int replaceSeq})? placement,
  ]) {
    final seq = follow.nextSeq++;
    final eventsForStream = type == 'assistant/message' &&
        context.sessionGeneration == 'v3' &&
        follow.assistantAttempt != null
        ? <String, Object?>{...data, 'stream': follow.assistantAttempt!.stream}
        : data;
    final event = <String, Object?>{
      'type': type,
      'seq': seq,
      'time': DateTime.now().millisecondsSinceEpoch,
      'data': codexAdaptEventData(type, eventsForStream, context.sessionGeneration),
      if (codexIsSurfaceEvent(type))
        if (placement == null)
          'surfaceOp': 'append'
        else ...<String, Object?>{
          'surfaceOp': context.sessionGeneration == 'v3'
              ? <String, Object?>{
                  'op': 'replace',
                  'startSeq': placement.replaceSeq,
                  'endSeq': placement.replaceSeq,
                }
              : <String, Object?>{
                  'op': 'replace',
                  'start': placement.replaceSeq,
                  'end': placement.replaceSeq,
                },
          'sourceEventSeqs': <Object?>[placement.replaceSeq],
        },
    };
    cacheImageBlocks(follow.sessionId, codexRecord(event['data']));
    follow.queue.push(<String, Object?>{
      'type': 'event',
      'event': event,
      if (view != null) 'view': view,
    });
    return seq;
  }

  void cacheImageBlocks(String sessionId, Object? value) {
    for (final block in codexCollectImageBlocks(value)) {
      final record = codexRecord(block);
      final attachment = codexRecord(record['attachment']);
      final attachmentId = codexString(attachment['attachmentId']);
      final data = codexString(record['data']);
      if (attachmentId == null || data == null) continue;
      if (!attachmentId.startsWith(codexImageAttachmentPrefix)) continue;
      context.imageAttachments[attachmentId] = <String, Object?>{
        'sessionId': sessionId,
        'attachment': attachment,
        'data': data,
      };
    }
  }

  CodexStreamBlock ensureStreamBlock(
    CodexLiveFollow follow,
    String key,
    String itemId,
    String kind,
  ) {
    final current = follow.streamedBlocks[key];
    if (current != null) return current;
    final block = CodexStreamBlock(
      itemId: itemId,
      index: follow.nextBlockIndex++,
      kind: kind,
      text: '',
    );
    follow.streamedBlocks[key] = block;
    follow.streamActive = true;
    pushAssistantChunk(follow, <String, Object?>{
      'type': 'block-start',
      'index': block.index,
      'blockType': kind,
    });
    return block;
  }

  void appendStreamDelta(
    CodexLiveFollow follow,
    String key,
    String itemId,
    String kind,
    String delta,
  ) {
    final block = ensureStreamBlock(follow, key, itemId, kind);
    final updated = block.copyWith(text: codexAppendBoundedText(block.text, delta));
    follow.streamedBlocks[key] = updated;
    pushAssistantChunk(follow, <String, Object?>{
      'type': kind == 'reasoning' ? 'reasoning-delta' : 'text-delta',
      'index': updated.index,
      'text': delta,
    });
  }

  void closeItemStreamBlocks(CodexLiveFollow follow, String itemId, String? fallback) {
    final matches = follow.streamedBlocks.entries.where((entry) => entry.value.itemId == itemId).toList();
    for (final entry in matches) {
      final block = entry.value;
      final text = block.text.isNotEmpty ? block.text : (fallback ?? '');
      pushAssistantChunk(follow, <String, Object?>{
        'type': 'block-end',
        'index': block.index,
        'block': <String, Object?>{'type': block.kind, 'text': text},
      });
      follow.streamedBlocks.remove(entry.key);
    }
  }

  void closeAllStreamBlocks(CodexLiveFollow follow) {
    for (final block in follow.streamedBlocks.values) {
      pushAssistantChunk(follow, <String, Object?>{
        'type': 'block-end',
        'index': block.index,
        'block': <String, Object?>{'type': block.kind, 'text': block.text},
      });
    }
    follow.streamedBlocks.clear();
  }

  void finishStream(CodexLiveFollow follow) {
    pushAssistantChunk(follow, <String, Object?>{
      'type': 'finish',
      'reason': <String, Object?>{'kind': 'stop'},
    });
    follow.streamActive = false;
  }

  void pushAssistantChunk(CodexLiveFollow follow, Map<String, Object?> chunk) {
    if (context.sessionGeneration != 'v3') {
      pushEvent(follow, 'assistant/chunk', <String, Object?>{
        'turn': follow.turn,
        'step': 1,
        'chunk': chunk,
      });
      return;
    }
    var attempt = follow.assistantAttempt;
    if (attempt == null) {
      attempt = CodexAssistantAttempt(
        attemptId: 'codex-attempt:${follow.activeTurnId ?? follow.turn}:${follow.nextSeq}',
        startedAfterSeq: follow.nextSeq - 1,
        nextIndex: 0,
        stream: const <Object?>[],
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

  void endAssistantAttempt(CodexLiveFollow follow, Map<String, Object?> outcome) {
    final attempt = follow.assistantAttempt;
    if (attempt == null) return;
    follow.assistantAttempt = null;
    follow.assistantStreamRevision += 1;
    if (context.sessionGeneration != 'v3') return;
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

  void ensureToolStarted(CodexLiveFollow follow, Map<String, Object?> item) {
    final itemId = codexString(item['id']);
    if (itemId == null) return;
    follow.startedItems.add(itemId);
    follow.liveItems[itemId] = item;
    for (final event in codexItemEvents(
      item,
      follow.turn,
      1,
      follow.requestId,
      context.modelSelection(follow.sessionId),
      follow.sessionId,
    )) {
      if (codexString(event['type']) != 'tool/call') continue;
      final marker = '$itemId:call';
      if (follow.liveToolResultSeq.containsKey(marker)) continue;
      pushEvent(
        follow,
        'tool/call',
        codexRecord(event['data']),
        event['view'] is Map ? Map<String, Object?>.from(event['view'] as Map) : null,
      );
      follow.liveToolResultSeq[marker] = -1;
    }
  }

  void emitToolResult(CodexLiveFollow follow, Map<String, Object?> item, String resultText) {
    final itemId = codexString(item['id']);
    if (itemId == null) return;
    final result = codexToolResultEvent(item, follow.turn, 1, itemId, resultText);
    if (result == null) return;
    pushToolResult(follow, itemId, result);
  }

  void pushToolResult(CodexLiveFollow follow, String itemId, Map<String, Object?> event) {
    final previous = follow.liveToolResultSeq[itemId];
    final projected = previous == null ? event : codexToolResultContentReplacement(event);
    final seq = pushEvent(
      follow,
      codexString(projected['type']) ?? 'tool/result',
      codexRecord(projected['data']),
      projected['view'] is Map ? Map<String, Object?>.from(projected['view'] as Map) : null,
      previous == null ? null : (replaceSeq: previous),
    );
    follow.liveToolResultSeq[itemId] = seq;
  }

  void resetLiveTurn(CodexLiveFollow follow) {
    follow.startedItems.clear();
    follow.completedItems.clear();
    follow.streamedBlocks.clear();
    follow.nextBlockIndex = 0;
    follow.streamActive = false;
    follow.assistantAttempt = null;
    follow.liveItems.clear();
    follow.liveToolOutput.clear();
    follow.liveToolResultSeq.clear();
    follow.pendingToolImages.clear();
  }

  void closeFollowAfterRemoteStreamClosed(CodexLiveFollow follow) {
    follows.remove(follow);
    follow.queue.close();
    context.emitRemoteEvent('api-session/status', <Object?>[follow.sessionId, false]);
  }

  Map<String, Object?> _projectCodexModel(Map<String, Object?> value) {
    final candidates = <Object?>[
      for (final turn in codexArray(value['turns']).reversed) turn,
      value,
    ];
    for (final candidate in candidates) {
      final record = codexRecord(candidate);
      final model = codexString(record['model']) ?? codexString(record['modelId']);
      if (model == null || model.isEmpty) continue;
      final effort = codexString(record['reasoningEffort']) ?? codexString(record['effort']);
      return <String, Object?>{
        'model': model,
        if (effort != null && effort.isNotEmpty) 'reasoningEffort': effort,
      };
    }
    return const <String, Object?>{};
  }
}

