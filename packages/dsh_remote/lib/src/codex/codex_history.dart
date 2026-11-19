/// Native Codex thread history projection and pagination, a faithful Dart port
/// of the official Web client's `dist/codex/virtual-history.js` (571 lines).
///
/// The App Server returns native `{turns: [{items: [...]}]}` records. The
/// official client projects those into the DSH virtual history shape
/// (`{header, entries, lastSeq, nextTurn}`), paginates them by surface-event
/// count, and adapts legacy `surfaceOp.replace {start,end}` to v3
/// `{startSeq,endSeq}`. Every name, constant, time fallback and string below
/// mirrors that module verbatim; no UI code lives here.
library;

import 'dart:convert';

import '../util/bytes.dart';
import 'codex_catalog.dart';
import 'codex_image_codec.dart';
import 'codex_turn_end.dart';
import 'codex_values.dart';

/// `MAX_LIVE_TOOL_OUTPUT` in the official module.
const int _maxLiveToolOutput = 128 * 1024;

/// `DEFAULT_HISTORY_MESSAGES` in the official module.
const int _defaultHistoryMessages = 50;

final Set<String> _toolItemTypes = <String>{
  'commandExecution',
  'mcpToolCall',
  'dynamicToolCall',
  'fileChange',
  'functionCallOutput',
  'hookPrompt',
  'collabAgentToolCall',
  'subAgentActivity',
  'webSearch',
  'imageView',
  'imageGeneration',
  'sleep',
  'enteredReviewMode',
  'exitedReviewMode',
  'contextCompaction',
};

final Map<String, String> _humanizedItemTypes = <String, String>{
  'functionCallOutput': 'CodeX function output',
  'hookPrompt': 'CodeX hook prompt',
  'dynamicToolCall': 'CodeX tool',
  'collabAgentToolCall': 'CodeX subagent',
  'subAgentActivity': 'CodeX subagent activity',
  'webSearch': 'CodeX web search',
  'imageView': 'CodeX image view',
  'imageGeneration': 'CodeX image generation',
  'sleep': 'CodeX wait',
  'enteredReviewMode': 'CodeX review mode',
  'exitedReviewMode': 'CodeX review mode',
  'contextCompaction': 'CodeX context compaction',
};

int? _nonZeroTime(int value) => value == 0 ? null : value;

/// Mirrors `JSON.stringify` for the arguments string and the fallback item id.
String _jsonString(Object? value) {
  try {
    return jsonEncode(value);
  } on Object {
    return value.toString();
  }
}

/// Client-core `projectCodexModel`, also private in `codex_catalog.dart`.
/// Kept local so this file can be imported independently.
Map<String, Object?> _projectCodexModel(Map<String, Object?> thread) {
  final candidates = <Object?>[
    for (final turn in codexArray(thread['turns']).reversed) turn,
    thread,
  ];
  for (final candidate in candidates) {
    final record = codexRecord(candidate);
    if (record.isEmpty && candidate is! Map) continue;
    final rawModel = codexString(record['model']);
    final model = rawModel != null && rawModel.isNotEmpty
        ? rawModel
        : (codexString(record['modelId']) is String && (codexString(record['modelId']) ?? '').isNotEmpty
            ? codexString(record['modelId'])
            : null);
    if (model == null) continue;
    final rawEffort = codexString(record['reasoningEffort']);
    final effort = rawEffort != null && rawEffort.isNotEmpty
        ? rawEffort
        : (codexString(record['effort']) is String && (codexString(record['effort']) ?? '').isNotEmpty
            ? codexString(record['effort'])
            : null);
    return <String, Object?>{'model': model, if (effort != null) 'reasoningEffort': effort};
  }
  return const <String, Object?>{};
}

Map<String, Object?> _modelSelection(Map<String, Object?>? base) {
  if (base == null) return codexModelSelection();
  final model = codexString(base['model']);
  if (model == null) return codexModelSelection();
  final effort = codexString(base['reasoningEffort']);
  return <String, Object?>{
    'provider': 'codex',
    'model': model,
    if (effort != null) 'reasoningEffort': effort,
  };
}

Map<String, Object?> _itemSelection(Map<String, Object?> item, Map<String, Object?> fallback) {
  final model = _projectCodexModel(item);
  final modelName = codexString(model['model']);
  if (modelName == null) return fallback;
  final effort = codexString(model['reasoningEffort']);
  return <String, Object?>{
    'provider': fallback['provider'],
    'model': modelName,
    if (effort != null) 'reasoningEffort': effort,
  };
}

/// Selection derived from a turn record in `projectCodexNativeHistory`, where
/// the upstream code hardcodes `provider: 'codex'`.
Map<String, Object?> _turnSelection(Map<String, Object?> turn, Map<String, Object?> fallback) {
  final model = _projectCodexModel(turn);
  final modelName = codexString(model['model']);
  if (modelName == null) return fallback;
  final effort = codexString(model['reasoningEffort']);
  return <String, Object?>{
    'provider': 'codex',
    'model': modelName,
    if (effort != null) 'reasoningEffort': effort,
  };
}

bool _isActiveCodexTurn(Map<String, Object?> turn) =>
    turn['status'] == 'inProgress' || turn['status'] == 'running';

String? _activeTurnId(Object? value) {
  final turns = codexArray(value);
  for (var index = turns.length - 1; index >= 0; index -= 1) {
    final turn = codexRecord(turns[index]);
    final id = codexString(turn['id']);
    if (_isActiveCodexTurn(turn) && id != null && id.isNotEmpty) return id;
  }
  return null;
}

/// `messageContent`: prefers real content blocks, falls back to a text block,
/// then appends tool-output images under a derived attachment seed.
List<JsonMap> _messageContent(
  Map<String, Object?> item,
  String attachmentSeed,
  String fallbackType,
  String? fallbackText, [
  List<Object?> supplementalImages = const <Object?>[],
]) {
  final source = item['content'] ?? item['input'];
  final blocks = codexContentBlocks(source, attachmentSeed);
  final images = codexContentBlocks(supplementalImages, '$attachmentSeed:tool-output');
  final fallback = <JsonMap>[
    <String, Object?>{'type': fallbackType, 'text': fallbackText ?? ''},
  ];
  if (blocks.isNotEmpty || images.isNotEmpty) {
    return <JsonMap>[
      ...(blocks.isNotEmpty ? blocks : fallback),
      ...images,
    ];
  }
  return fallback;
}

/// `itemText`, in the exact precedence order of the official module.
String? codexItemText(Object? value) {
  final record = codexRecord(value);
  final text = record['text'];
  if (text is String) return text;
  final content = record['content'];
  if (content is String) return content;
  final parts = content is List<Object?> ? content : (record['input'] is List ? codexArray(record['input']) : null);
  if (parts != null) {
    final joined = parts.map((part) {
      if (part is String) return part;
      final block = codexRecord(part);
      return codexString(block['text']) ?? codexString(block['content']) ?? '';
    }).where((part) => part.isNotEmpty).join('\n');
    if (joined.isNotEmpty) return joined;
  }
  final summary = record['summary'];
  if (summary is List) {
    return summary.whereType<String>().join('\n');
  }
  final output = record['output'];
  if (output is String) return output;
  final aggregated = record['aggregatedOutput'];
  if (aggregated is String) return aggregated;
  return null;
}

bool codexIsToolItemType(String? type) => type != null && _toolItemTypes.contains(type);

bool codexIsSurfaceEvent(String type) =>
    type == 'user/message' || type == 'assistant/message' || type == 'tool/result';

/// `toolEventName` (private upstream, exported here for the virtual bridge).
String codexToolEventName(String type) => switch (type) {
      'fileChange' => 'codex.fileChange',
      'commandExecution' => 'codex.command',
      'webSearch' => 'codex.webSearch',
      'collabAgentToolCall' || 'subAgentActivity' => 'codex.subagent',
      'imageView' || 'imageGeneration' => 'codex.image',
      'enteredReviewMode' || 'exitedReviewMode' => 'codex.reviewMode',
      'contextCompaction' => 'codex.compaction',
      _ => 'codex.$type',
    };

String? codexCommandText(Object? value) {
  if (value is String) return value;
  if (value is List) {
    return value.whereType<String>().join(' ');
  }
  final source = codexRecord(value);
  return codexString(source['command']) ?? codexString(source['text']);
}

/// Official `fileChangeSummary(item)`; extended to accept the `changes` array
/// itself so callers holding `item['changes']` can pass it directly.
String codexFileChangeSummary(Object? changes) {
  final source = changes is Map<String, Object?> && changes.containsKey('changes') ? changes['changes'] : changes;
  final parts = codexArray(source).map((raw) {
    final change = codexRecord(raw);
    final path = codexString(change['path']);
    final rawKind = change['kind'];
    final kind = rawKind is String ? rawKind : codexString(codexRecord(rawKind)['type']);
    return <String>[
      if (kind != null && kind.isNotEmpty) kind,
      if (path != null && path.isNotEmpty) path,
    ].join(' ');
  }).where((part) => part.isNotEmpty);
  final joined = parts.join('\n');
  return joined.isEmpty ? 'File changes completed.' : joined;
}

/// Official `sanitizedFileChanges(value)`; also accepts an item record whose
/// `changes` key holds the array.
List<Object?> codexSanitizedFileChanges(Object? changes) {
  final source = changes is Map<String, Object?> && changes.containsKey('changes') ? changes['changes'] : changes;
  final result = <Object?>[];
  for (final raw in codexArray(source)) {
    final change = codexRecord(raw);
    final path = codexString(change['path']);
    if (path == null) continue;
    final rawKind = change['kind'];
    final kind = rawKind is String ? rawKind : codexString(codexRecord(rawKind)['type']);
    result.add(<String, Object?>{
      'path': path,
      if (kind != null) 'kind': kind,
    });
  }
  return result;
}

String codexAppendBoundedText(String left, String right) {
  final value = left + right;
  if (value.length <= _maxLiveToolOutput) return value;
  return '… earlier output omitted …\n${value.substring(value.length - _maxLiveToolOutput)}';
}

Map<String, Object?> _toolArguments(Map<String, Object?> item) {
  final type = codexString(item['type']);
  if (type == 'commandExecution') {
    return <String, Object?>{'command': codexCommandText(item['command']) ?? item['command'] ?? ''};
  }
  if (type == 'fileChange') {
    final changes = <Object?>[];
    for (final raw in codexArray(item['changes'])) {
      final change = codexRecord(raw);
      final rawKind = change['kind'];
      final kind = rawKind is String ? rawKind : codexString(codexRecord(rawKind)['type']);
      changes.add(<String, Object?>{
        if (codexString(change['path']) != null) 'path': change['path'],
        if (kind != null) 'kind': kind,
      });
    }
    return <String, Object?>{'changes': changes};
  }
  if (type == 'webSearch') {
    return <String, Object?>{'query': codexString(item['query']) ?? ''};
  }
  if (type == 'imageView') {
    return <String, Object?>{'path': codexString(item['path']) ?? ''};
  }
  if (type == 'imageGeneration') {
    final prompt = codexString(item['revisedPrompt']);
    return <String, Object?>{
      if (prompt != null) 'prompt': prompt,
      'transparentBackground': item['transparentBackground'] == true,
    };
  }
  if (type == 'collabAgentToolCall') {
    return <String, Object?>{
      'tool': codexString(item['tool']) ?? 'collaboration',
      'receiverThreadIds': codexArray(item['receiverThreadIds']).whereType<String>().toList(),
      if (codexString(item['model']) != null) 'model': item['model'],
    };
  }
  if (type == 'subAgentActivity') {
    final rawKind = item['kind'];
    final kind = codexString(codexRecord(rawKind)['type']) ?? codexString(rawKind) ?? 'activity';
    return <String, Object?>{
      'agentThreadId': codexString(item['agentThreadId']) ?? '',
      'agentPath': codexString(item['agentPath']) ?? '',
      'kind': kind,
    };
  }
  if (type == 'sleep') {
    return <String, Object?>{'durationMs': codexInteger(item['durationMs']) ?? 0};
  }
  if (type == 'enteredReviewMode' || type == 'exitedReviewMode') {
    return <String, Object?>{'review': codexString(item['review']) ?? ''};
  }
  if (type == 'contextCompaction') {
    return const <String, Object?>{};
  }
  return <String, Object?>{
    'name': item['name'] ?? item['tool'] ?? item['type'] ?? 'tool',
    'arguments': item['arguments'] ?? item['input'] ?? <String, Object?>{},
  };
}

String _humanizeItemType(String type) => _humanizedItemTypes[type] ?? 'CodeX tool';

String _toolDisplayName(Map<String, Object?> item, String type) {
  final tool = item['tool'];
  return codexString(item['name']) ??
      codexString(tool) ??
      codexString(codexRecord(tool)['name']) ??
      (type == 'mcpToolCall' ? 'CodeX MCP tool' : _humanizeItemType(type));
}

List<Map<String, Object?>> _fileLocations(Map<String, Object?> item) {
  final locations = <Map<String, Object?>>[];
  for (final raw in codexArray(item['changes'])) {
    final path = codexString(codexRecord(raw)['path']);
    if (path != null && path.isNotEmpty) locations.add(<String, Object?>{'path': path});
  }
  return locations;
}

Map<String, Object?> _toolCallView(Map<String, Object?> item, String type, Map<String, Object?> args) {
  if (type == 'commandExecution') {
    final cwd = codexString(item['cwd']);
    return <String, Object?>{
      'card': 'terminal',
      'title': codexCommandText(item['command']) ?? 'CodeX command',
      if (cwd != null) 'cwd': cwd,
    };
  }
  final locations = _fileLocations(item);
  if (type == 'fileChange') {
    final count = locations.length;
    return <String, Object?>{
      'card': 'generic',
      'title': count == 0 ? 'CodeX file changes' : 'Modify $count file${count == 1 ? '' : 's'}',
      'kind': 'edit',
      'rawInput': args,
      if (count != 0) 'locations': locations,
    };
  }
  if (type == 'webSearch') {
    return <String, Object?>{
      'card': 'generic',
      'title': codexString(item['query']) ?? 'CodeX web search',
      'kind': 'search',
      'rawInput': args,
    };
  }
  if (type == 'imageView' || type == 'imageGeneration') {
    final path = codexString(item['path']) ?? codexString(item['savedPath']);
    return <String, Object?>{
      'card': 'generic',
      'title': type == 'imageView' ? 'View image' : 'Generate image',
      'kind': type == 'imageView' ? 'read' : 'other',
      if (path != null) 'locations': <Object?>[<String, Object?>{'path': path}],
    };
  }
  if (type == 'collabAgentToolCall' || type == 'subAgentActivity') {
    final title = type == 'collabAgentToolCall'
        ? 'Subagent: ${codexString(item['tool']) ?? 'collaboration'}'
        : 'Subagent activity: ${codexString(item['agentPath']) ?? codexString(item['agentThreadId']) ?? 'agent'}';
    return <String, Object?>{
      'card': 'generic',
      'title': title,
      'kind': 'other',
      'rawInput': args,
    };
  }
  if (type == 'contextCompaction') {
    return const <String, Object?>{'card': 'generic', 'title': 'Compact conversation context', 'kind': 'other'};
  }
  if (type == 'enteredReviewMode') {
    return const <String, Object?>{'card': 'generic', 'title': 'Enter review mode', 'kind': 'other'};
  }
  if (type == 'exitedReviewMode') {
    return const <String, Object?>{'card': 'generic', 'title': 'Exit review mode', 'kind': 'other'};
  }
  return <String, Object?>{
    'card': 'generic',
    'title': _toolDisplayName(item, type),
    'kind': 'other',
  };
}

Map<String, Object?> _toolResultView(Map<String, Object?> item, String type, String resultText) {
  if (type == 'commandExecution') {
    final exitCode = codexInteger(item['exitCode']);
    return <String, Object?>{
      'card': 'terminal',
      'output': resultText,
      if (exitCode != null) 'exitCode': exitCode,
    };
  }
  return <String, Object?>{
    'card': 'generic',
    if (type == 'fileChange')
      'title': item['status'] == 'inProgress' ? 'CodeX file changes' : 'CodeX file changes completed',
    if (type == 'mcpToolCall' && item['status'] == 'inProgress') ...<String, Object?>{
      'title': 'CodeX MCP tool in progress',
      'content': <Object?>[<String, Object?>{'type': 'text', 'text': resultText}],
    },
  };
}

String _toolResultText(Map<String, Object?> item, String type, String? text) {
  if (type == 'fileChange') return codexFileChangeSummary(item['changes']);
  if (type == 'webSearch') {
    final count = codexArray(item['results']).length;
    return count == 0 ? 'Web search completed.' : 'Web search returned $count result${count == 1 ? '' : 's'}.';
  }
  if (type == 'imageView') return 'Viewed image: ${codexString(item['path']) ?? 'image'}';
  if (type == 'imageGeneration') {
    final savedPath = codexString(item['savedPath']);
    return savedPath == null
        ? 'Image generation ${codexString(item['status']) ?? 'completed'}.'
        : 'Generated image: $savedPath';
  }
  if (type == 'contextCompaction') return 'CodeX compacted the conversation context.';
  if (type == 'enteredReviewMode') {
    final review = codexString(item['review']);
    return review != null && review.isNotEmpty ? 'Entered review mode: $review' : 'Entered review mode.';
  }
  if (type == 'exitedReviewMode') {
    final review = codexString(item['review']);
    return review != null && review.isNotEmpty ? 'Exited review mode: $review' : 'Exited review mode.';
  }
  if (type == 'sleep') return 'Waited ${codexInteger(item['durationMs']) ?? 0} ms.';
  if (type == 'subAgentActivity') {
    final rawKind = item['kind'];
    final kind = codexString(codexRecord(rawKind)['type']) ?? codexString(rawKind) ?? 'Subagent activity';
    final agentPath = codexString(item['agentPath']);
    return agentPath == null ? kind : '$kind: $agentPath';
  }
  return text ??
      codexItemText(item['result']) ??
      codexItemText(item['output']) ??
      codexString(item['status']) ??
      type;
}

/// `itemEvents` from the official module: one user message, one assistant
/// message, or a `tool/call` + `tool/result` pair (plus a view for each).
List<Map<String, Object?>> codexItemEvents(
  Map<String, Object?> item,
  int turn,
  int step,
  Object? requestId,
  Map<String, Object?> selection,
  String sessionId, [
  List<Object?> supplementalImages = const <Object?>[],
]) {
  final type = codexString(item['type']);
  final id = codexString(item['id']) ?? '$turn:$step:${codexHashString(_jsonString(item))}';
  final text = codexItemText(item);
  final effectiveSelection = _itemSelection(item, selection);
  final modelSource = <String, Object?>{
    'kind': 'model',
    'provider': effectiveSelection['provider'],
    'model': effectiveSelection['model'],
  };

  if (type == 'userMessage') {
    return <Map<String, Object?>>[
      <String, Object?>{
        'type': 'user/message',
        'data': <String, Object?>{
          'id': id,
          'role': 'user',
          'content': _messageContent(item, '$sessionId:$id', 'text', text),
          'source': requestId == null || requestId == ''
              ? <String, Object?>{'kind': 'user'}
              : <String, Object?>{'kind': 'user', 'rpcId': requestId},
        },
      },
    ];
  }
  if (type == 'agentMessage' || type == 'reasoning' || type == 'plan') {
    return <Map<String, Object?>>[
      <String, Object?>{
        'type': 'assistant/message',
        'data': <String, Object?>{
          'turn': turn,
          'step': step,
          'message': <String, Object?>{
            'id': id,
            'role': 'assistant',
            'content': _messageContent(
              item,
              '$sessionId:$id',
              type == 'reasoning' ? 'reasoning' : 'text',
              text,
              type == 'agentMessage' ? supplementalImages : const <Object?>[],
            ),
            'source': modelSource,
          },
        },
      },
    ];
  }
  if (type != null && codexIsToolItemType(type)) {
    final name = codexToolEventName(type);
    final args = _toolArguments(item);
    final callEvent = <String, Object?>{
      'type': 'tool/call',
      'data': <String, Object?>{
        'turn': turn,
        'step': step,
        'callId': id,
        'name': name,
        'arguments': _jsonString(args),
      },
      'view': <String, Object?>{'for': 'call', 'view': _toolCallView(item, type, args)},
    };
    return <Map<String, Object?>>[
      callEvent,
      codexToolResultEvent(item, turn, step, id, _toolResultText(item, type, text))!,
    ];
  }
  if (type == 'error') {
    return <Map<String, Object?>>[
      <String, Object?>{
        'type': 'assistant/message',
        'data': <String, Object?>{
          'turn': turn,
          'step': step,
          'message': <String, Object?>{
            'id': id,
            'role': 'assistant',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': text ?? 'CodeX reported an error.'},
            ],
            'source': modelSource,
          },
        },
      },
    ];
  }
  return const <Map<String, Object?>>[];
}

/// `toolResultEvent` from the official module.
Map<String, Object?>? codexToolResultEvent(
  Map<String, Object?> item,
  int turn,
  int step,
  String itemId,
  String resultText,
) {
  final type = codexString(item['type']) ?? 'unknown';
  return <String, Object?>{
    'type': 'tool/result',
    'data': <String, Object?>{
      'turn': turn,
      'step': step,
      'message': <String, Object?>{
        'id': '$itemId:result',
        'role': 'user',
        'content': <Object?>[
          <String, Object?>{
            'type': 'tool-result',
            'toolCallId': itemId,
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': resultText},
            ],
            if (item['status'] == 'failed' || item['success'] == false) 'isError': true,
          },
        ],
        'source': <String, Object?>{'kind': 'tool', 'callId': itemId},
      },
    },
    'view': <String, Object?>{'for': 'result', 'view': _toolResultView(item, type, resultText)},
  };
}

/// Removes the transient `isError` flag from a `tool/result` content block,
/// keeping the event identity stable for the virtual history surface.
Map<String, Object?> codexToolResultContentReplacement(Map<String, Object?> event) {
  final data = codexRecord(event['data']);
  final message = codexRecord(data['message']);
  final content = codexArray(message['content']);
  final result = codexRecord(content.isEmpty ? null : content.first);
  if (result['isError'] == null) return event;
  final stableResult = <String, Object?>{...result}..remove('isError');
  return <String, Object?>{
    ...event,
    'data': <String, Object?>{
      ...data,
      'message': <String, Object?>{
        ...message,
        'content': <Object?>[stableResult],
      },
    },
  };
}

/// v3 assistant messages always carry a `stream` array, even when the Host
/// supplied no streaming information.
Map<String, Object?> codexAdaptEventData(String type, Map<String, Object?> data, String generation) {
  if (generation != 'v3' || type != 'assistant/message') return data;
  if (data['stream'] is List) return data;
  return <String, Object?>{...data, 'stream': <Object?>[]};
}

/// Projects a native Codex thread into a virtual history envelope.
///
/// [generation] is `'v3'` or `'legacy'`; v3 sets `header.version = 3` and
/// `header.isSeeded = false`. Active turns have no synthetic `step/end` or
/// `turn/end` events, matching the official module exactly.
Map<String, Object?> codexProjectCodexNativeHistory(
  Map<String, Object?> thread,
  String sessionId,
  String generation,
) {
  final entries = <Map<String, Object?>>[];
  var seq = 0;
  var turnNumber = 0;
  final active = _activeTurnId(thread['turns']);
  final projected = codexProjectThread(thread);
  final fallbackSelection = _modelSelection(_projectCodexModel(thread));

  int append(
    String type,
    Map<String, Object?> data, {
    required int time,
    Object? view,
    List<Object?>? sourceEventSeqs,
  }) {
    final eventSeq = seq++;
    entries.add(<String, Object?>{
      'type': 'event',
      'event': <String, Object?>{
        'type': type,
        'seq': eventSeq,
        'time': time,
        'data': codexAdaptEventData(type, data, generation),
        if (sourceEventSeqs != null) 'sourceEventSeqs': sourceEventSeqs,
        if (codexIsSurfaceEvent(type)) 'surfaceOp': 'append',
      },
      if (view != null) 'view': view,
    });
    return eventSeq;
  }

  for (final rawTurn in codexArray(thread['turns'])) {
    final turn = codexRecord(rawTurn);
    final turnItems = codexArray(turn['items']).map(codexRecord).toList(growable: false);
    final toolImages = <Object?>[
      for (final item in turnItems) ...codexToolOutputImageBlocks(item),
    ];
    var imageOwner = -1;
    for (var index = 0; index < turnItems.length; index += 1) {
      if (turnItems[index]['type'] == 'agentMessage') imageOwner = index;
    }
    turnNumber += 1;
    final turnActive = _isActiveCodexTurn(turn);
    final turnSelection = _turnSelection(turn, fallbackSelection);
    final time = _nonZeroTime(codexNormalizeTime(turn['createdAt'])) ??
        _nonZeroTime(codexNormalizeTime(turn['startedAt'])) ??
        _nonZeroTime(codexNormalizeTime(thread['createdAt'])) ??
        DateTime.now().millisecondsSinceEpoch;
    append('turn/start', <String, Object?>{'turn': turnNumber}, time: time);
    append('step/start', <String, Object?>{'turn': turnNumber, 'step': 1}, time: time);

    int? toolCallSeq;
    for (var itemIndex = 0; itemIndex < turnItems.length; itemIndex += 1) {
      final item = turnItems[itemIndex];
      final selection = turnSelection;
      final supplemental = itemIndex == imageOwner ? toolImages : const <Object?>[];
      final itemTime = _nonZeroTime(codexNormalizeTime(item['createdAt'])) ?? time;
      for (final event in codexItemEvents(item, turnNumber, 1, null, selection, sessionId, supplemental)) {
        final eventType = codexString(event['type']) ?? '';
        final eventSeq = append(
          eventType,
          codexRecord(event['data']),
          time: itemTime,
          view: event['view'],
          sourceEventSeqs: eventType == 'tool/result' && toolCallSeq != null
              ? <Object?>[toolCallSeq]
              : null,
        );
        if (eventType == 'tool/call') toolCallSeq = eventSeq;
      }
    }
    if (turnActive) continue;
    final endTime = _nonZeroTime(codexNormalizeTime(turn['updatedAt'])) ??
        _nonZeroTime(codexNormalizeTime(turn['completedAt'])) ??
        time;
    append('step/end', <String, Object?>{'turn': turnNumber, 'step': 1}, time: endTime);
    append(
      'turn/end',
      <String, Object?>{'turn': turnNumber, 'reason': codexTurnEndReason(turn)},
      time: endTime,
    );
  }

  final isV3 = generation == 'v3';
  return <String, Object?>{
    'header': <String, Object?>{
      'version': isV3 ? 3 : 1,
      'id': sessionId,
      'createdAt': projected?['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
      if (projected?['cwd'] != null) 'cwd': projected!['cwd'],
      if (projected?['model'] != null) 'model': projected!['model'],
      if (projected?['reasoningEffort'] != null) 'reasoningEffort': projected!['reasoningEffort'],
      if (isV3) 'isSeeded': false,
    },
    'entries': entries,
    'lastSeq': seq - 1,
    'nextTurn': turnNumber,
    if (active != null) 'activeTurnId': active,
  };
}

/// `paginateCodexNativeHistory`: cuts the window at the message that exceeds
/// [request] `maxMessages` (default 50), including any linked tool-call event.
Map<String, Object?> codexPaginateCodexNativeHistory(
  Map<String, Object?> history,
  Map<String, Object?> request,
) {
  final lastSeq = codexInteger(history['lastSeq']) ?? -1;
  final requestedThrough = codexInteger(request['throughSeq']) ?? lastSeq;
  final throughSeq = requestedThrough < lastSeq ? requestedThrough : lastSeq;
  final beforeSeq = codexInteger(request['beforeSeq']);
  final noBefore = beforeSeq == null;
  final requestedEnd = noBefore ? throughSeq : beforeSeq - 1;
  final endSeq = requestedEnd < throughSeq ? requestedEnd : throughSeq;

  final entries = <Map<String, Object?>>[
    for (final raw in codexArray(history['entries'])) codexRecord(raw),
  ];
  int? seqOf(Map<String, Object?> entry) => codexInteger(codexRecord(entry['event'])['seq']);
  final window = endSeq < 0
      ? <Map<String, Object?>>[]
      : entries.where((entry) {
          final eventSeq = seqOf(entry);
          return eventSeq != null && eventSeq <= endSeq;
        }).toList(growable: false);
  final maxMessages = codexInteger(request['maxMessages']) ?? _defaultHistoryMessages;
  var messages = 0;
  var cut = 0;
  for (var index = window.length - 1; index >= 0; index -= 1) {
    final event = codexRecord(window[index]['event']);
    final type = codexString(event['type']) ?? '';
    if (!codexIsSurfaceEvent(type) || event['surfaceOp'] != 'append') continue;
    messages += 1;
    if (messages >= maxMessages) {
      var minSeq = codexInteger(event['seq']) ?? 0;
      for (final raw in codexArray(event['sourceEventSeqs'])) {
        final sourceSeq = codexInteger(raw);
        if (sourceSeq != null && sourceSeq < minSeq) minSeq = sourceSeq;
      }
      cut = minSeq;
      break;
    }
  }
  return <String, Object?>{
    'header': history['header'],
    'cursor': lastSeq,
    'nextTurn': history['nextTurn'],
    'records': window.where((entry) {
      final eventSeq = seqOf(entry);
      return eventSeq != null && eventSeq >= cut;
    }).toList(growable: false),
    'hasMore': window.any((entry) {
      final eventSeq = seqOf(entry);
      return eventSeq != null && eventSeq < cut;
    }),
    if (history['activeTurnId'] != null) 'activeTurnId': history['activeTurnId'],
  };
}

/// Rewrites legacy pages to the v3 shape: strips `seedLength`, normalizes
/// `surfaceOp.replace {start,end}` to `{startSeq,endSeq}`, and makes sure every
/// assistant message carries a `stream` array.
Map<String, Object?> codexAdaptCodexHistoryPage(Object? value, String generation) {
  if (generation != 'v3') return codexRecord(value);
  final page = codexRecord(value);
  final sourceHeader = codexRecord(page['header']);
  final header = <String, Object?>{...sourceHeader}..remove('seedLength');
  final rawRecords = page['records'];
  final records = rawRecords is List
      ? <Object?>[
          for (final raw in rawRecords) _adaptCodexHistoryRecord(raw),
        ]
      : rawRecords;
  return <String, Object?>{
    ...page,
    'header': <String, Object?>{
      ...header,
      'version': 3,
      'isSeeded': sourceHeader['isSeeded'] == true,
    },
    'records': records,
  };
}

Map<String, Object?> _adaptCodexHistoryRecord(Object? raw) {
  final entry = codexRecord(raw);
  final sourceEvent = codexRecord(entry['event']);
  final sourceSurfaceOp = codexRecord(sourceEvent['surfaceOp']);
  final Object? surfaceOp;
  if (sourceEvent['surfaceOp'] == 'append') {
    surfaceOp = 'append';
  } else if (sourceSurfaceOp['op'] == 'replace' &&
      codexInteger(sourceSurfaceOp['startSeq']) != null &&
      codexInteger(sourceSurfaceOp['endSeq']) != null) {
    surfaceOp = sourceSurfaceOp;
  } else if (sourceSurfaceOp['op'] == 'replace' &&
      codexInteger(sourceSurfaceOp['start']) != null &&
      codexInteger(sourceSurfaceOp['end']) != null) {
    surfaceOp = <String, Object?>{
      'op': 'replace',
      'startSeq': sourceSurfaceOp['start'],
      'endSeq': sourceSurfaceOp['end'],
    };
  } else {
    surfaceOp = sourceEvent['surfaceOp'];
  }
  return <String, Object?>{
    ...entry,
    'event': <String, Object?>{
      ...sourceEvent,
      'data': codexAdaptEventData(
        codexString(sourceEvent['type']) ?? '',
        codexRecord(sourceEvent['data']),
        'v3',
      ),
      if (surfaceOp != null) 'surfaceOp': surfaceOp,
    },
  };
}

/// Structural check used before feeding a cached payload into the live bridge.
bool codexIsCodexNativeHistoryPage(Object? value, String sessionId) {
  final page = codexRecord(value);
  final header = codexRecord(page['header']);
  final activeTurnId = page['activeTurnId'];
  return header['id'] == sessionId &&
      codexInteger(page['cursor']) != null &&
      codexInteger(page['nextTurn']) != null &&
      page['records'] is List &&
      page['hasMore'] is bool &&
      (activeTurnId == null || activeTurnId is String);
}
