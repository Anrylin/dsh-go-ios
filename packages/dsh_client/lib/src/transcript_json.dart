/// JSON codec for the transcript window [TranscriptCache] keeps.
///
/// The cache only paints a conversation until the first Host snapshot lands, so
/// the format is deliberately narrow: it stores the rows a chat list can rebuild
/// without the network, and refuses a window it cannot rebuild exactly (an
/// unknown part) instead of caching a wrong row. Live drafts and pending
/// approvals stay out: a restart must never show a dead prompt.
library;

import 'json.dart';
import 'models.dart';
import 'transcript.dart';

/// Shape version of a cached window; files with another version are dropped.
const transcriptCacheVersion = 1;

/// Shape version of the sidecar that keeps a live (unsettled) draft.
const transcriptDraftVersion = 1;

class CachedTranscript {
  const CachedTranscript({
    required this.account,
    required this.hostId,
    required this.sessionId,
    required this.cursor,
    required this.items,
    this.title,
    this.hasMoreHistory = false,
  });

  /// The local account the window was read under; `''` when it was unknown
  /// (a cold start reads the cache before the Host answered).
  final String account;

  /// Host and session identity the file was written for.
  final String hostId;
  final String sessionId;

  /// The snapshot cursor these rows were read at.
  final int cursor;
  final String? title;
  final bool hasMoreHistory;
  final List<ChatItem> items;

  /// Encodes the window; `null` when a row holds content this codec cannot
  /// rebuild, in which case the previous window stays on disk.
  Map<String, Object?>? toJson() {
    final rows = <Object?>[];
    for (final item in items) {
      // Streaming rows (and tool calls whose arguments are still arriving) live
      // in the sidecar only: a window with a `seq == null` row cannot be trusted
      // after a restart, and one bad row must not lose the whole durable view.
      if (item is AssistantChatItem && (item.streaming || item.seq == null)) continue;
      if (item is ToolChatItem && item.seq == null) continue;
      final row = _rowJson(item);
      if (row == null) return null;
      rows.add(row);
    }
    if (rows.isEmpty) return null;
    return {
      'v': transcriptCacheVersion,
      'account': account,
      'host': hostId,
      'session': sessionId,
      'cursor': cursor,
      'more': hasMoreHistory,
      'title': ?title,
      'items': rows,
    };
  }

  /// Reads a window; `null` for another version or a shape the codec cannot
  /// trust (corrupt file, a row past [cursor], a live draft).
  static CachedTranscript? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null || asInt(map['v']) != transcriptCacheVersion) return null;
    final hostId = asString(map['host']);
    final sessionId = asString(map['session']);
    final cursor = asInt(map['cursor']);
    if (hostId == null || hostId.isEmpty) return null;
    if (sessionId == null || sessionId.isEmpty) return null;
    if (cursor == null || cursor < 1) return null;
    final items = <ChatItem>[];
    for (final row in asListOrEmpty(map['items'])) {
      final item = _itemFromJson(row);
      if (item == null) return null;
      final seq = _seqOf(item);
      if (seq == null || seq > cursor) return null;
      items.add(item);
    }
    if (items.isEmpty) return null;
    return CachedTranscript(
      account: asString(map['account']) ?? '',
      hostId: hostId,
      sessionId: sessionId,
      cursor: cursor,
      title: asString(map['title']),
      hasMoreHistory: map['more'] == true,
      items: items,
    );
  }
}

/// The live side of a conversation: a full visible snapshot that may contain
/// rows the durable window deliberately omits (a streaming assistant draft, a
/// tool call whose arguments are still arriving).
///
/// Kept in a separate `*.draft.json` file so the durable window keeps its
/// narrow contract: a restart paints the draft, and the first authoritative
/// Host snapshot deletes the sidecar. An approval request is never restored —
/// it was live on the old device and cannot be answered after a restart.
class CachedDraft {
  const CachedDraft({
    required this.account,
    required this.hostId,
    required this.sessionId,
    required this.cursor,
    required this.revision,
    required this.items,
    this.title,
    this.hasMoreHistory = false,
  });

  final String account;
  final String hostId;
  final String sessionId;

  /// Sequence cursor the visible rows were read at (`-1` before any snapshot).
  final int cursor;

  /// Bumped whenever the live draft changes; part of the app's write dedup key.
  final int revision;
  final String? title;
  final bool hasMoreHistory;
  final List<ChatItem> items;

  /// `null` when a row holds content this codec cannot rebuild, in which case
  /// the previous sidecar stays on disk.
  Map<String, Object?>? toJson() {
    final rows = <Object?>[];
    for (final item in items) {
      final row = _rowJson(item, draft: true);
      if (row == null) return null;
      rows.add(row);
    }
    if (rows.isEmpty) return null;
    return {
      'v': transcriptDraftVersion,
      'account': account,
      'host': hostId,
      'session': sessionId,
      'cursor': cursor,
      'rev': revision,
      'more': hasMoreHistory,
      'title': ?title,
      'items': rows,
    };
  }

  /// Reads a draft; `null` for another version or an untrustworthy shape.
  static CachedDraft? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null || asInt(map['v']) != transcriptDraftVersion) return null;
    final hostId = asString(map['host']);
    final sessionId = asString(map['session']);
    final cursor = asInt(map['cursor']);
    final revision = asInt(map['rev']);
    if (hostId == null || hostId.isEmpty) return null;
    if (sessionId == null || sessionId.isEmpty) return null;
    if (cursor == null || cursor < -1) return null;
    if (revision == null || revision < 0) return null;
    final items = <ChatItem>[];
    for (final row in asListOrEmpty(map['items'])) {
      final item = _itemFromJson(row, draft: true);
      if (item == null) return null;
      final seq = _seqOf(item);
      if (seq != null && seq > cursor) return null;
      items.add(item);
    }
    if (items.isEmpty) return null;
    return CachedDraft(
      account: asString(map['account']) ?? '',
      hostId: hostId,
      sessionId: sessionId,
      cursor: cursor,
      revision: revision,
      title: asString(map['title']),
      hasMoreHistory: map['more'] == true,
      items: items,
    );
  }
}

Map<String, Object?>? _rowJson(ChatItem item, {bool draft = false}) {
  switch (item) {
    case UserChatItem(
      :final seq,
      :final time,
      :final text,
      :final images,
      :final files,
      :final requestId,
      :final sourceKind,
    ):
      if (seq < 1) return null;
      return {
        'type': 'u',
        'seq': seq,
        'time': time.millisecondsSinceEpoch,
        'text': text,
        'images': [for (final image in images) image.toJson()],
        'files': [
          for (final file in files) {'attachmentId': ?file.attachmentId, 'name': ?file.name, 'bytes': ?file.bytes},
        ],
        'requestId': ?requestId,
        'source': sourceKind,
      };
    case AssistantChatItem(
      :final id,
      :final rowKey,
      :final seq,
      :final time,
      :final text,
      :final reasoning,
      :final interrupted,
      :final usage,
      :final model,
      :final streaming,
    ):
      if (!draft && (seq == null || seq < 1)) return null;
      if (draft && seq != null && seq < 1) return null;
      return {
        'type': 'a',
        'id': id,
        'rowKey': ?rowKey,
        'seq': ?seq,
        'time': ?time?.millisecondsSinceEpoch,
        'text': text,
        'reasoning': reasoning,
        'interrupted': interrupted,
        'usage': ?_usageJson(usage),
        'model': ?model,
        if (draft && streaming) 'streaming': true,
      };
    case ToolChatItem(
      :final callId,
      :final name,
      :final arguments,
      :final status,
      :final seq,
      :final resultParts,
      :final failure,
      :final approvalOutcome,
      :final meta,
    ):
      if (!draft && (seq == null || seq < 1)) return null;
      if (draft && seq != null && seq < 1) return null;
      final parts = <Object?>[];
      for (final part in resultParts) {
        final partJson = _partJson(part);
        if (partJson == null) return null;
        parts.add(partJson);
      }
      return {
        'type': 't',
        'callId': callId,
        'name': name,
        'arguments': arguments,
        'seq': ?seq,
        'status': draft ? _draftStatusName(status) : _statusName(status),
        'parts': parts,
        'failure': ?_toolFailureJson(failure),
        'outcome': ?_outcomeWire(approvalOutcome),
        'meta': ?meta,
      };
    case NoticeChatItem(:final seq, :final kind, :final text, :final failure):
      if (seq < 1) return null;
      return {'type': 'n', 'seq': seq, 'kind': kind, 'text': text, 'failure': ?_failureJson(failure)};
  }
}

ChatItem? _itemFromJson(Object? json, {bool draft = false}) {
  final map = asMap(json);
  if (map == null) return null;
  final seq = asInt(map['seq']);
  if (!draft && (seq == null || seq < 1)) return null;
  if (draft && seq != null && seq < 1) return null;
  switch (asString(map['type'])) {
    case 'u':
      final time = asEpochMs(map['time']);
      final text = asString(map['text']);
      if (time == null || text == null || seq == null) return null;
      final images = <ImageAttachment>[];
      for (final raw in asListOrEmpty(map['images'])) {
        if (asMap(raw) == null) return null;
        images.add(ImageAttachment.fromJson(raw));
      }
      final files = <FileAttachment>[];
      for (final raw in asListOrEmpty(map['files'])) {
        if (asMap(raw) == null) return null;
        files.add(FileAttachment.fromJson(raw));
      }
      return UserChatItem(
        seq: seq,
        time: time,
        text: text,
        images: images,
        files: files,
        requestId: asString(map['requestId']),
        sourceKind: asString(map['source']) ?? 'user',
      );
    case 'a':
      final id = asString(map['id']);
      final text = asString(map['text']);
      final reasoning = asString(map['reasoning']);
      if (id == null || text == null || reasoning == null) return null;
      final rawUsage = map['usage'];
      final usage = rawUsage == null ? null : TokenUsage.fromJson(rawUsage);
      if (rawUsage != null && usage == null) return null;
      return AssistantChatItem(
        id: id,
        rowKey: asString(map['rowKey']),
        seq: seq,
        time: asEpochMs(map['time']),
        text: text,
        reasoning: reasoning,
        interrupted: map['interrupted'] == true,
        usage: usage,
        model: asString(map['model']),
        streaming: draft && map['streaming'] == true,
      );
    case 't':
      final callId = asString(map['callId']);
      final name = asString(map['name']);
      final arguments = asString(map['arguments']);
      final status = draft ? _draftStatusFromName(asString(map['status'])) : _statusFromName(asString(map['status']));
      if (callId == null || name == null || arguments == null || status == null) return null;
      final parts = <Part>[];
      for (final raw in asListOrEmpty(map['parts'])) {
        final part = _partFromJson(raw);
        if (part == null) return null;
        parts.add(part);
      }
      final rawFailure = map['failure'];
      final failure = rawFailure == null ? null : _toolFailureFromJson(rawFailure);
      if (rawFailure != null && failure == null) return null;
      final rawOutcome = map['outcome'];
      if (rawOutcome != null && rawOutcome is! String) return null;
      return ToolChatItem(
        callId: callId,
        name: name,
        arguments: arguments,
        status: status,
        seq: seq,
        resultParts: parts,
        failure: failure,
        approvalOutcome: rawOutcome == null ? null : ApprovalOutcome.parse(rawOutcome),
        meta: map['meta'],
      );
    case 'n':
      final kind = asString(map['kind']);
      final text = asString(map['text']);
      if (kind == null || text == null || seq == null) return null;
      final rawFailure = map['failure'];
      final failure = rawFailure == null ? null : _failureFromJson(rawFailure);
      if (rawFailure != null && failure == null) return null;
      return NoticeChatItem(seq: seq, kind: kind, text: text, failure: failure);
    default:
      return null;
  }
}

int? _seqOf(ChatItem item) => switch (item) {
  UserChatItem(:final seq) => seq,
  AssistantChatItem(:final seq) => seq,
  ToolChatItem(:final seq) => seq,
  NoticeChatItem(:final seq) => seq,
};

/// Wire name of a durable tool row; the transient states are not cached.
String _statusName(ToolStatus status) => switch (status) {
  ToolStatus.succeeded => 'succeeded',
  ToolStatus.failed => 'failed',
  ToolStatus.denied => 'denied',
  ToolStatus.cancelled => 'cancelled',
  ToolStatus.streaming || ToolStatus.running || ToolStatus.awaitingApproval => 'running',
};

ToolStatus? _statusFromName(String? name) => switch (name) {
  'running' => ToolStatus.running,
  'succeeded' => ToolStatus.succeeded,
  'failed' => ToolStatus.failed,
  'denied' => ToolStatus.denied,
  'cancelled' => ToolStatus.cancelled,
  _ => null,
};

/// A draft may show arguments still streaming, but an approval request is
/// live: it is written as `running`, never as an answerable `awaitingApproval`.
String _draftStatusName(ToolStatus status) => switch (status) {
  ToolStatus.streaming => 'streaming',
  ToolStatus.awaitingApproval => 'running',
  _ => _statusName(status),
};

ToolStatus? _draftStatusFromName(String? name) => switch (name) {
  'streaming' => ToolStatus.streaming,
  _ => _statusFromName(name),
};

String? _outcomeWire(ApprovalOutcome? outcome) => switch (outcome) {
  null => null,
  ApprovalOutcome.allowedOnce => 'allowed-once',
  ApprovalOutcome.rejected => 'rejected',
  ApprovalOutcome.cancelled => 'cancelled',
  ApprovalOutcome.unavailable => 'unavailable',
  ApprovalOutcome.unknown => 'unknown',
};

Map<String, Object?>? _usageJson(TokenUsage? usage) {
  if (usage == null) return null;
  return {
    'inputTokens': usage.inputTokens,
    'outputTokens': usage.outputTokens,
    'totalTokens': ?usage.totalTokens,
    'cacheReadTokens': ?usage.cacheReadTokens,
    'cacheWriteTokens': ?usage.cacheWriteTokens,
    'reasoningTokens': ?usage.reasoningTokens,
  };
}

Map<String, Object?>? _failureJson(LlmFailure? failure) {
  if (failure == null) return null;
  return {'message': failure.message, 'code': failure.code, 'status': ?failure.status};
}

LlmFailure? _failureFromJson(Object? json) {
  final map = asMap(json);
  if (map == null) return null;
  final message = asString(map['message']);
  final code = asString(map['code']);
  if (message == null || code == null) return null;
  return LlmFailure(message: message, code: code, status: asInt(map['status']));
}

Map<String, Object?>? _toolFailureJson(ToolFailure? failure) {
  if (failure == null) return null;
  return {'name': failure.name, 'code': failure.code, 'reason': ?failure.reason};
}

ToolFailure? _toolFailureFromJson(Object? json) {
  final map = asMap(json);
  if (map == null) return null;
  final name = asString(map['name']);
  final code = asString(map['code']);
  if (name == null || code == null) return null;
  return ToolFailure(name, code, asString(map['reason']));
}

Map<String, Object?>? _partJson(Part part) => switch (part) {
  TextPart(:final text) => {'type': 'text', 'text': text},
  ReasoningPart(:final text) => {'type': 'reasoning', 'text': text},
  ImagePart(:final attachment, :final offloaded) => {
    'type': 'image',
    'attachment': attachment.toJson(),
    'offloaded': offloaded,
  },
  FilePart(:final attachment) => {
    'type': 'file',
    'attachment': {'attachmentId': ?attachment.attachmentId, 'name': ?attachment.name, 'bytes': ?attachment.bytes},
  },
  ToolCallPart(:final id, :final name, :final arguments) => {
    'type': 'tool-call',
    'id': id,
    'name': name,
    'arguments': arguments,
  },
  UnknownPart() => null,
};

Part? _partFromJson(Object? json) {
  final part = Part.fromJson(json);
  return part is UnknownPart ? null : part;
}
