/// Byte-capped window files for conversations that were on screen, so a
/// reopened or restarted conversation paints before the Host answers.
///
/// Give this cache the App's private support directory, never an export
/// directory. One isolate owns a directory; instances in that isolate share a
/// queue. Cache I/O is best-effort: a failed read is a miss and a failed write a
/// no-op, because the Host snapshot is always the truth.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'json.dart';
import 'transcript_json.dart';

/// Recent transcript windows, least recently used evicted first.
class TranscriptCache {
  TranscriptCache({
    required Directory directory,
    this.maxEntries = 8,
    this.maxEntryBytes = 2 * 1024 * 1024,
    this.maxTotalBytes = 16 * 1024 * 1024,
    int Function()? nowMilliseconds,
  }) : _directory = directory,
       _now = nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Directory _directory;
  final int Function() _now;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;

  /// One queue per directory, like the companion store: a save and a prune
  /// must not race the same files.
  static final _queues = <String, Future<void>>{};

  /// The window kept for [sessionId] on [hostId], or `null`.
  ///
  /// [account] is the local account when it is known: a window written under
  /// another account is stale and returns `null` (an unknown account reads
  /// whatever the identity-free path holds).
  Future<CachedTranscript?> load({required String hostId, required String sessionId, String? account}) {
    return _serialized(() async {
      try {
        final file = _file(hostId, sessionId);
        if (!await file.exists()) return null;
        if (await file.length() > maxEntryBytes) {
          await _delete(file);
          return null;
        }
        CachedTranscript? window;
        try {
          window = CachedTranscript.fromJson(jsonDecode(await file.readAsString()));
        } catch (_) {
          // A truncated or unparsable file is not a window worth keeping.
          await _delete(file);
          return null;
        }
        if (window == null || window.hostId != hostId || window.sessionId != sessionId) {
          await _delete(file);
          return null;
        }
        final known = account;
        if (known != null && known.isNotEmpty && window.account.isNotEmpty && known != window.account) {
          await _delete(file);
          return null;
        }
        await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(_now()));
        return window;
      } catch (_) {
        return null;
      }
    });
  }

  /// Writes [window] atomically, then evicts the least recently used windows.
  /// An unencodable or too-large window is not written at all.
  Future<void> save(CachedTranscript window) {
    return _serialized(() async {
      File? temporary;
      try {
        final payload = window.toJson();
        if (payload == null) return;
        final bytes = utf8.encode(jsonEncode(payload));
        if (bytes.length > maxEntryBytes) return;
        final file = _file(window.hostId, window.sessionId);
        await file.parent.create(recursive: true);
        temporary = File.fromUri(file.uri.resolve('${file.uri.pathSegments.last}.tmp-${uuidV4()}').normalizePath());
        await temporary.create(exclusive: true);
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(_now()));
        await _prune();
      } catch (_) {
        // A cache write never fails the conversation it describes.
      } finally {
        try {
          if (temporary != null) await temporary.delete();
        } on FileSystemException {
          /* Missing after rename, or best effort cleanup. */
        }
      }
    });
  }

  /// Drops the windows written under [account] (the others stay).
  Future<void> clearAccount(String account) {
    if (account.isEmpty) return Future.value();
    return _serialized(() async {
      try {
        await for (final entity in _directory.list(recursive: true, followLinks: false)) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          try {
            final window = CachedTranscript.fromJson(jsonDecode(await entity.readAsString()));
            if (window != null && window.account == account) await _delete(entity);
          } catch (_) {
            // An unreadable window is not provably this account's to keep.
          }
        }
      } catch (_) {
        // A missing cache directory has nothing to clear.
      }
    });
  }

  /// Drops every window (sign-out, account switch).
  Future<void> clearAll() {
    return _serialized(() async {
      try {
        if (await _directory.exists()) await _directory.delete(recursive: true);
      } catch (_) {
        // The next save recreates the directory.
      }
    });
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final key = _directory.absolute.path;
    final result = (_queues[key] ?? Future<void>.value()).then((_) => action());
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _queues[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return result;
  }

  /// `<host tag>/<session tag>.json`: hashes keep arbitrary ids as safe names,
  /// and the tags keep one Host's sessions out of another's files.
  File _file(String hostId, String sessionId) =>
      File.fromUri(_directory.absolute.uri.resolve('h-${_tag(hostId)}/s-${_tag(sessionId)}.json').normalizePath());

  Future<void> _prune() async {
    final stats = <File, FileStat>{};
    await for (final entity in _directory.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        stats[entity] = await entity.stat();
      } on FileSystemException {
        /* Gone meanwhile: nothing to keep or evict. */
      }
    }
    final files = stats.keys.toList()..sort((a, b) => stats[b]!.modified.compareTo(stats[a]!.modified));
    var kept = 0;
    var bytes = 0;
    for (final file in files) {
      kept++;
      bytes += stats[file]!.size;
      if (kept <= maxEntries && bytes <= maxTotalBytes) continue;
      await _delete(file);
    }
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      /* Already gone, or owned by another writer: best effort. */
    }
  }
}

/// FNV-1a based file tag: deterministic across runs, unlike [Object.hash].
/// Two 32-bit lanes keep it well beyond collision range for eight windows.
String _tag(String value) {
  var low = 0x811c9dc5;
  var high = 0x9e3779b9;
  for (final unit in utf8.encode(value)) {
    low = ((low ^ unit) * 0x01000193) & 0xffffffff;
    high = ((high ^ unit) * 0x85ebca6b) & 0xffffffff;
  }
  return low.toRadixString(16).padLeft(8, '0') + high.toRadixString(16).padLeft(8, '0');
}
