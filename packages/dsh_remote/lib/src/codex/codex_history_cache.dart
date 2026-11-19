/// History-page cache for the virtual Codex bridge, a faithful Dart port of
/// `CodexSessionHistoryCache` in the official plugin bundle
/// (`dist/index.js` L66737–66870), plus a small `get`/`set` facade used by the
/// pure-Dart virtual harness.
///
/// The JS class tracks a per-thread LRU of page payloads (8 entries), a global
/// LRU of threads (32 entries), an epoch-based invalidation table (256 keys)
/// and single-flight pages. Dart has no `AbortSignal`, so [runSingleFlightPage]
/// accepts an optional `cancelled` future instead, mirroring the convention
/// already used in `codex_contract.dart`.
library;

import 'dart:async';
import 'dart:convert';

import 'codex_values.dart';

/// `MAX_CACHED_SESSIONS` in the official module.
const int codexHistoryMaxCachedSessions = 32;

/// `MAX_UNARY_PAGES_PER_SESSION` in the official module.
const int codexHistoryMaxUnaryPagesPerSession = 8;

/// `MAX_INVALIDATION_KEYS` in the official module.
const int codexHistoryMaxInvalidationKeys = 256;

/// Raised when every waiter of a single-flight page cancels before it settles.
class CodexHistoryAbortedException implements Exception {
  const CodexHistoryAbortedException([this.reason]);

  final Object? reason;

  @override
  String toString() => 'CodexHistoryAbortedException: ${reason ?? 'The operation was aborted.'}';
}

class _CodexHistoryThreadEntry {
  _CodexHistoryThreadEntry();

  bool stale = false;
  int? updatedAt;
  Map<String, Object?>? tailPage;
  final Map<String, Map<String, Object?>> pages = <String, Map<String, Object?>>{};
}

class _CodexPendingPage {
  late Future<Map<String, Object?>> promise;
  int waiters = 0;
  bool settled = false;
}

class _HistoryOutcome {
  const _HistoryOutcome();
}

class _HistoryPageValue extends _HistoryOutcome {
  const _HistoryPageValue(this.value);

  final Map<String, Object?> value;
}

class _HistoryPageError extends _HistoryOutcome {
  const _HistoryPageError(this.error);

  final Object error;
}

class _HistoryPageCancelled extends _HistoryOutcome {
  const _HistoryPageCancelled(this.reason);

  final Object? reason;
}

class _CancelledMarker {
  const _CancelledMarker(this.reason);

  final Object? reason;
}

class _NotCancelledMarker {
  const _NotCancelledMarker();
}

void _touchLru<T>(Map<String, T> map, String key, T value, int maxEntries) {
  map.remove(key);
  map[key] = value;
  while (map.length > maxEntries) {
    if (map.isEmpty) break;
    map.remove(map.keys.first);
  }
}

/// `structuredClone` (with a JSON fallback) in the official module. History
/// payloads are JSON values, so a recursive copy is equivalent here.
Object? _cloneValue(Object? value) {
  if (value is Map<String, Object?>) {
    return value.map<String, Object?>((key, item) => MapEntry<String, Object?>(key, _cloneValue(item)));
  }
  if (value is Map<Object?, Object?>) {
    return value.map<Object?, Object?>((key, item) => MapEntry<Object?, Object?>(key, _cloneValue(item)));
  }
  if (value is List<Object?>) {
    return value.map(_cloneValue).toList(growable: true);
  }
  return value;
}

Map<String, Object?> _clonePage(Map<String, Object?> value) => _cloneValue(value) as Map<String, Object?>;

String? _string(Object? value) => value is String ? value : null;

int? _integer(Object? value) => codexInteger(value);

int? _normalizeUpdatedAt(Object? value) {
  final time = codexNormalizeTime(value);
  return time == 0 ? null : time;
}
/// Official `CodexSessionHistoryCache`, with the small `get`/`set` facade
/// expected by the Dart virtual harness.
class CodexSessionHistoryCache {
  CodexSessionHistoryCache();

  final Map<String, _CodexHistoryThreadEntry> _threads = <String, _CodexHistoryThreadEntry>{};
  final Map<String, _CodexPendingPage> _pendingPages = <String, _CodexPendingPage>{};
  final Map<String, int> _invalidatedAt = <String, int>{};
  int _epoch = 0;
  int _minValidEpoch = 0;

  /// `CodexSessionHistoryCache.pageKey`.
  static String pageKey(String generation, Map<String, Object?> page) => jsonEncode(<Object?>[
        generation,
        page['beforeSeq'],
        page['throughSeq'],
        page['maxMessages'],
      ]);

  /// Native thread id of a projected or raw Codex thread.
  ///
  /// Prefixed session ids are stripped with `codexNativeThreadId`; a bare id is
  /// accepted as-is so callers never hit its strict-format exception here.
  static String threadIdOf(Map<String, Object?> thread) {
    final rawId = _string(thread['nativeId']) ?? _string(thread['id']);
    if (rawId != null && rawId.isNotEmpty) {
      if (rawId.startsWith(codexSessionPrefix)) return codexNativeThreadId(rawId);
      return rawId;
    }
    final sessionId = _string(thread['sessionId']);
    if (sessionId == null || sessionId.isEmpty) return '';
    if (sessionId.startsWith(codexSessionPrefix)) return codexNativeThreadId(sessionId);
    return sessionId;
  }

  int beginReadEpoch() => ++_epoch;

  bool isReadEpochValid(String threadId, int readEpoch) =>
      readEpoch > _minValidEpoch && readEpoch > (_invalidatedAt[threadId] ?? 0);

  /// Facade used by the Dart virtual layer: cached page for [key], or `null`.
  ///
  /// The thread's normalized `updatedAt` is used to mark the entry stale, as
  /// `session2.updatedAt` is used by the official `readHistoryPage`.
  Map<String, Object?>? get(Map<String, Object?> thread, String key) {
    final threadId = threadIdOf(thread);
    if (threadId.isEmpty) return null;
    final entry = _threads[threadId];
    if (entry == null || entry.stale) return null;
    final knownUpdatedAt = _normalizeUpdatedAt(thread['updatedAt']);
    if (knownUpdatedAt != null && entry.updatedAt != null && knownUpdatedAt > entry.updatedAt!) {
      entry.stale = true;
      return null;
    }
    final cached = entry.pages[key];
    if (cached == null) return null;
    _touchLru(entry.pages, key, cached, codexHistoryMaxUnaryPagesPerSession);
    _touchLru(_threads, threadId, entry, codexHistoryMaxCachedSessions);
    return _clonePage(cached);
  }

  /// Facade used by the Dart virtual layer: stores a cloned copy of [value].
  void set(Map<String, Object?> thread, String key, Map<String, Object?> value) {
    final threadId = threadIdOf(thread);
    if (threadId.isEmpty) return;
    final entry = _threads[threadId] ?? _CodexHistoryThreadEntry();
    if (entry.stale) {
      entry.pages.clear();
      entry.tailPage = null;
      entry.stale = false;
    }
    final knownUpdatedAt = _normalizeUpdatedAt(thread['updatedAt']);
    if (knownUpdatedAt != null) entry.updatedAt = knownUpdatedAt;
    _touchLru(entry.pages, key, _clonePage(value), codexHistoryMaxUnaryPagesPerSession);
    _touchLru(_threads, threadId, entry, codexHistoryMaxCachedSessions);
  }

  /// Official `getFreshPage`.
  Map<String, Object?>? getFreshPage(
    String threadId,
    String generation,
    Map<String, Object?> page, {
    Object? knownUpdatedAt,
  }) {
    final entry = _threads[threadId];
    if (entry == null || entry.stale) return null;
    final knownTime = _normalizeUpdatedAt(knownUpdatedAt);
    if (knownTime != null && entry.updatedAt != null && knownTime > entry.updatedAt!) {
      entry.stale = true;
      return null;
    }
    final key = pageKey(generation, page);
    final cached = entry.pages[key];
    if (cached == null) return null;
    _touchLru(entry.pages, key, cached, codexHistoryMaxUnaryPagesPerSession);
    _touchLru(_threads, threadId, entry, codexHistoryMaxCachedSessions);
    return _clonePage(cached);
  }

  /// Official `getFreshTailCursor`.
  int? getFreshTailCursor(
    String threadId,
    String generation, {
    Object? knownUpdatedAt,
  }) {
    final entry = _threads[threadId];
    if (entry == null || entry.stale || entry.tailPage == null) return null;
    final knownTime = _normalizeUpdatedAt(knownUpdatedAt);
    if (knownTime != null && entry.updatedAt != null && knownTime > entry.updatedAt!) {
      entry.stale = true;
      return null;
    }
    final header = _record(entry.tailPage!['header']);
    final pageGeneration = header['version'] == 3 ? 'v3' : 'legacy';
    if (pageGeneration != generation) return null;
    _touchLru(_threads, threadId, entry, codexHistoryMaxCachedSessions);
    return _integer(entry.tailPage!['cursor']);
  }

  /// Official `getStalePage`, used as a fallback when the Host RPC fails.
  Map<String, Object?>? getStalePage(String threadId, String generation, Map<String, Object?> page) {
    final entry = _threads[threadId];
    if (entry == null) return null;
    final cached = entry.pages[pageKey(generation, page)];
    return cached == null ? null : _clonePage(cached);
  }

  /// Official `setPage`.
  void setPage(
    String threadId,
    String generation,
    Map<String, Object?> page,
    Map<String, Object?> value, {
    Object? knownUpdatedAt,
    int? readEpoch,
  }) {
    if (readEpoch != null && !isReadEpochValid(threadId, readEpoch)) return;
    final entry = _threads[threadId] ?? _CodexHistoryThreadEntry();
    if (entry.stale) {
      entry.pages.clear();
      entry.tailPage = null;
      entry.stale = false;
    }
    final knownTime = _normalizeUpdatedAt(knownUpdatedAt);
    if (knownTime != null) entry.updatedAt = knownTime;
    final cloned = _clonePage(value);
    _touchLru(entry.pages, pageKey(generation, page), cloned, codexHistoryMaxUnaryPagesPerSession);
    if (page['beforeSeq'] == null && page['throughSeq'] == null) entry.tailPage = cloned;
    _touchLru(_threads, threadId, entry, codexHistoryMaxCachedSessions);
  }

  /// Official `runSingleFlightPage`.
  ///
  /// [factory] starts the shared RPC; [cancelled] completes with a reason when
  /// the caller aborts, and [onAllWaitersCancelled] lets the caller abort the
  /// underlying RPC once no waiter remains (the JS `AbortController` role).
  Future<Map<String, Object?>> runSingleFlightPage(
    String threadId,
    String generation,
    Map<String, Object?> page,
    Future<Map<String, Object?>> Function() factory, {
    Future<Object?>? cancelled,
    void Function()? onAllWaitersCancelled,
  }) async {
    // Matches the JS `if (signal?.aborted) throw signal.reason` check without
    // blocking on a cancellation future that has not fired yet.
    if (cancelled != null) {
      final raced = await Future.any<Object?>(<Future<Object?>>[
        cancelled.then<Object?>((reason) => _CancelledMarker(reason)),
        Future<Object?>.value(const _NotCancelledMarker()),
      ]);
      if (raced is _CancelledMarker) {
        throw raced.reason ?? const CodexHistoryAbortedException();
      }
    }
    final composite = '$threadId:${pageKey(generation, page)}';
    final existing = _pendingPages[composite];
    if (existing != null && !existing.settled) {
      return _attachSharedInFlight(existing, cancelled, onAllWaitersCancelled);
    }
    final entry = _CodexPendingPage();
    entry.promise = factory().whenComplete(() {
      entry.settled = true;
      if (identical(_pendingPages[composite], entry)) _pendingPages.remove(composite);
    });
    unawaited(entry.promise.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _pendingPages[composite] = entry;
    return _attachSharedInFlight(entry, cancelled, onAllWaitersCancelled);
  }

  Future<Map<String, Object?>> _attachSharedInFlight(
    _CodexPendingPage entry,
    Future<Object?>? cancelled,
    void Function()? onAllWaitersCancelled,
  ) async {
    entry.waiters += 1;
    if (cancelled == null) {
      final value = await entry.promise;
      return _clonePage(value);
    }
    final outcome = await Future.any<_HistoryOutcome>(<Future<_HistoryOutcome>>[
      entry.promise.then<_HistoryOutcome>(
        (value) => _HistoryPageValue(value),
        onError: (Object error, StackTrace stack) => _HistoryPageError(error),
      ),
      cancelled.then<_HistoryOutcome>((reason) => _HistoryPageCancelled(reason)),
    ]);
    if (outcome is _HistoryPageCancelled) {
      // Mirrors JS `onAbort`: only aborted waiters decrement the counter, and
      // the last one aborts the shared request while it is still unsettled.
      entry.waiters -= 1;
      if (entry.waiters <= 0 && !entry.settled) onAllWaitersCancelled?.call();
      if (outcome.reason != null) throw outcome.reason!;
      throw const CodexHistoryAbortedException();
    }
    if (outcome is _HistoryPageError) throw outcome.error;
    return _clonePage((outcome as _HistoryPageValue).value);
  }

  /// Official `invalidateThread`: marks the entry stale, bumps the epoch and
  /// settles pending single-flight pages for this thread.
  void invalidateThread(String threadId) {
    final invalidationEpoch = ++_epoch;
    _invalidatedAt.remove(threadId);
    _invalidatedAt[threadId] = invalidationEpoch;
    while (_invalidatedAt.length > codexHistoryMaxInvalidationKeys) {
      if (_invalidatedAt.isEmpty) break;
      final oldestKey = _invalidatedAt.keys.first;
      final oldestEpoch = _invalidatedAt[oldestKey] ?? 0;
      if (oldestEpoch > _minValidEpoch) _minValidEpoch = oldestEpoch;
      _invalidatedAt.remove(oldestKey);
    }
    final entry = _threads[threadId];
    if (entry != null) entry.stale = true;
    final prefix = '$threadId:';
    for (final key in _pendingPages.keys.toList(growable: false)) {
      if (!key.startsWith(prefix)) continue;
      _pendingPages[key]?.settled = true;
      _pendingPages.remove(key);
    }
  }

  /// Removes the thread entirely after invalidating its epoch.
  void removeThread(String threadId) {
    invalidateThread(threadId);
    _threads.remove(threadId);
  }

  /// Official `clear`.
  void clear() {
    _minValidEpoch = ++_epoch;
    _invalidatedAt.clear();
    _threads.clear();
    for (final pending in _pendingPages.values) {
      pending.settled = true;
    }
    _pendingPages.clear();
  }
}

Map<String, Object?> _record(Object? value) =>
    value is Map<String, Object?> ? value : <String, Object?>{};
