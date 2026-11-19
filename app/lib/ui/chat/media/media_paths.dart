// Pictures a media card already shows: a reply naming the same file
// (`![](generated/…/cat-1.png)`, which the plugin asks the model to write for
// clients without media cards) is not drawn a second time
// (docs/design/media-generation.md §2.5, 「网页版与旧 App」).

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/chat_state.dart';
import '../tool_view.dart' show toolMedia;

/// The memo lives in its own provider: a text/tool argument delta remakes the
/// transcript but leaves every finished item alone. Keep the same set for
/// those publishes; a durable log event (a result, a preset change) still
/// gives listeners a fresh set, as before.
final _mediaPathsMemoProvider = Provider.autoDispose.family<_MediaPathsMemo, String>((ref, sessionId) => _MediaPathsMemo());

/// Every file the conversation's media cards show.
final sessionMediaPathsProvider = Provider.autoDispose.family<Set<String>, String>((ref, sessionId) {
  final chat = ref.read(chatProvider(sessionId).notifier);
  final watched = ref.watch(chatProvider(sessionId).select((s) => (s.items, chat.events.length)));
  return ref.watch(_mediaPathsMemoProvider(sessionId)).forItems(watched.$1, watched.$2);
});

class _MediaPathsMemo {
  List<ChatItem>? _durable;
  int? _events;
  Set<String>? _value;

  Set<String> forItems(List<ChatItem> items, int events) {
    final durable = <ChatItem>[for (final item in items) if (!_isDraft(item)) item];
    final previous = _durable;
    if (_value != null &&
        _events == events &&
        previous != null &&
        _sameIdentities(previous, durable)) {
      return _value!;
    }
    _durable = durable;
    _events = events;
    return _value = <String>{
      for (final item in durable)
        if (item is ToolChatItem)
          if (toolMedia(item) case final media?) ...media.paths,
    };
  }

  /// The only items a stream rewrites: no durable seq yet and no result.
  static bool _isDraft(ChatItem item) => switch (item) {
    AssistantChatItem(:final seq, :final streaming) => seq == null && streaming,
    ToolChatItem(:final seq, :final status) =>
      seq == null &&
          (status == ToolStatus.streaming || status == ToolStatus.running) &&
          item.resultParts.isEmpty &&
          item.meta == null &&
          item.pendingApproval == null,
    _ => false,
  };

  static bool _sameIdentities(List<ChatItem> a, List<ChatItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}

/// Whether [path] (absolute, or relative to the conversation's folder when
/// the app doesn't know it) is one of [shown].
bool shownInMediaCard(Set<String> shown, String path) {
  if (shown.isEmpty || path.isEmpty) return false;
  if (shown.contains(path)) return true;
  if (path.startsWith('/')) return false;
  final relative = path.startsWith('./') ? path.substring(2) : path;
  return shown.any((p) => p.endsWith('/$relative'));
}

final _imageLine = RegExp(r'^[ \t]*!\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)[ \t]*$', multiLine: true);

/// [text] without the lines that only show a picture a media card already
/// shows (the paragraph would stay behind as a gap). Null when nothing goes.
String? withoutShownImages(String text, Set<String> shown) {
  if (shown.isEmpty || !text.contains('![')) return null;
  var changed = false;
  final out = text.replaceAllMapped(_imageLine, (m) {
    var target = m[1]!;
    try {
      target = Uri.decodeFull(target);
    } on ArgumentError {
      // Keep it as written.
    }
    if (!shownInMediaCard(shown, target)) return m[0]!;
    changed = true;
    return '';
  });
  if (!changed) return null;
  return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// [item] showing [text] instead.
AssistantChatItem replyWithText(AssistantChatItem item, String text) => AssistantChatItem(
  id: item.id,
  rowKey: item.rowKey,
  seq: item.seq,
  time: item.time,
  text: text,
  reasoning: item.reasoning,
  streaming: item.streaming,
  interrupted: item.interrupted,
  usage: item.usage,
  model: item.model,
);
