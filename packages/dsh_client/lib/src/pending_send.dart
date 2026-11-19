/// Durable outbox for prompts this App accepted and the Host has not taken yet.
///
/// A send is optimistic: the chat shows the message at once, and delivery may
/// finish after the App was backgrounded or restarted. This store keeps every
/// not-yet-delivered prompt by account, Host and session, so a later launch can
/// submit it again with the same `requestId` (`session/prompt` is idempotent).
///
/// Give this store the App's private support directory, never an export or
/// download directory. One isolate owns a directory; instances in that isolate
/// share a queue. Other isolates/processes must route their requests to that
/// owner.
///
/// Attachments are referenced by local file path, never copied as bytes: the
/// delivery reads and uploads them when it runs, and queuing a send must not
/// double the App's storage for a large image or file. A corrupt or oversized
/// file reads as no pending sends; the next write replaces it.
///
/// Failures throw [DshRemoteException] with stable codes (`pending-send/io-error`,
/// `pending-send/too-large`, `pending-send/invalid-request`) and a status in
/// `details`, like the other local stores.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'errors.dart';
import 'json.dart' show uuidV4;

const _fileName = 'pending-sends.json';

// One pending send is a few KB; this bounds the whole file, not one entry.
const _maxBytes = 4 * 1024 * 1024;
const _maxField = 512;
const _maxRequestId = 256;
const _maxPath = 4096;
const _maxAttachments = 32;
const _maxError = 512;
// One message's text, bounded so a huge pasted draft can never fill the whole
// device-wide outbox and stop every other session from queueing.
const _maxText = 64 * 1024;
// DateTime has a smaller range than JS safe integers.
const _maxDateTime = 8640000000000000;
const _keys = ['account', 'host', 'session', 'requestId', 'text', 'attachments', 'createdAt', 'attempts', 'lastError'];
typedef _Json = Map<String, Object?>;

final _queues = <String, Future<void>>{};

// Local failures keep the client's exception type and carry a status, but no
// file path or message text.
const _invalid = DshRemoteException('pending-send/invalid-request', 'Invalid pending send', {'status': 400});
const _ioError = DshRemoteException('pending-send/io-error', 'Pending send store operation failed', {'status': 500});
const _tooLarge = DshRemoteException('pending-send/too-large', 'Pending send store is full', {'status': 413});

/// Where a pending send belongs: the account and Host that must deliver it and
/// the session it was written into. A send is never delivered under another
/// account or Host than the one that accepted it.
class PendingSendKey {
  const PendingSendKey({required this.account, required this.host, required this.session});

  final String account;
  final String host;
  final String session;

  @override
  bool operator ==(Object other) =>
      other is PendingSendKey && other.account == account && other.host == host && other.session == session;

  @override
  int get hashCode => Object.hash(account, host, session);
}

/// One accepted send the Host has not confirmed, under the `requestId` its
/// delivery reuses so a retry cannot post the message twice.
class PendingSend {
  const PendingSend({
    required this.requestId,
    required this.text,
    required this.createdAt,
    this.attachments = const [],
    this.attempts = 0,
    this.lastError,
  });

  final String requestId;
  final String text;

  /// Local file paths, not bytes; the delivery uploads them itself.
  final List<String> attachments;

  /// When the person sent it. Pending sends load oldest first, in delivery
  /// order.
  final DateTime createdAt;
  final int attempts;

  /// Stable error code from the last failed attempt, not its message.
  final String? lastError;
}

class PendingSendStore {
  PendingSendStore({required Directory directory, this.maxPerSession = 20})
    : assert(maxPerSession > 0, 'maxPerSession must keep at least one send'),
      _file = File.fromUri(directory.absolute.uri.resolve(_fileName).normalizePath());

  final File _file;

  /// Pending sends kept per session; [add] drops the oldest beyond it.
  final int maxPerSession;

  /// Pending sends for [key], oldest first. Entries of other accounts, Hosts
  /// or sessions stay untouched.
  Future<List<PendingSend>> load(PendingSendKey key) => _transaction((doc) {
    final sends = [
      for (final entry in _entries(doc))
        if (_matches(entry, key)) _send(entry),
    ]..sort(_bySendAge);
    return sends;
  });

  /// Stores [send] and returns the entry it dropped from that session to stay
  /// within [maxPerSession], or null when there was room.
  ///
  /// The session's oldest entry goes first; the send being added stays even
  /// when the caller passes an older [PendingSend.createdAt], because the person
  /// just sent it. Adding a `requestId` that is already stored only rewrites its
  /// text, attachments and attempt history: it was re-added after a restart or
  /// an edit, and keeps its place in line.
  Future<PendingSend?> add(PendingSendKey key, PendingSend send) async {
    final entry = _entry(key, send);
    if (!_validEntry(entry)) throw _invalid;
    return _transaction((doc) async {
      final entries = _entries(doc);
      final index = entries.indexWhere((e) => _matches(e, key) && e['requestId'] == send.requestId);
      if (index >= 0) {
        final stored = entries[index];
        entry['createdAt'] = stored['createdAt'];
        entry['attempts'] = stored['attempts'];
        entry['lastError'] = stored['lastError'];
        entries[index] = entry;
        doc['sends'] = entries;
        _fit(doc, entry);
        await _write(doc);
        return null;
      }
      final bucket = [
        for (final e in entries)
          if (_matches(e, key)) e,
      ];
      PendingSend? dropped;
      if (bucket.length >= maxPerSession) {
        final oldest = bucket.reduce((a, b) => _byAge(a, b) <= 0 ? a : b);
        entries.remove(oldest);
        dropped = _send(oldest);
      }
      entries.add(entry);
      doc['sends'] = entries;
      // The device-wide byte cap is the store's, not a session's: a send must
      // never be refused because other sessions' entries filled it. Evict the
      // globally oldest entry (never the one being written) instead, and
      // report it like a session eviction.
      final evicted = _fit(doc, entry);
      dropped ??= evicted.isEmpty ? null : evicted.first;
      await _write(doc);
      return dropped;
    });
  }

  /// Drops the globally oldest entries until the encoded document fits the
  /// device-wide cap, keeping [entry] (the one being written). Returns what it
  /// removed so the caller can tell the person.
  List<PendingSend> _fit(_Json doc, _Json entry) {
    final removed = <PendingSend>[];
    while (utf8.encode(jsonEncode(doc)).length > _maxBytes) {
      final entries = _entries(doc);
      final candidates = [
        for (final e in entries)
          if (!identical(e, entry)) e,
      ];
      if (candidates.isEmpty) break;
      final oldest = candidates.reduce((a, b) => _byAge(a, b) <= 0 ? a : b);
      entries.remove(oldest);
      doc['sends'] = entries;
      removed.add(_send(oldest));
    }
    return removed;
  }

  /// Forgets the send once the Host took it, or the person withdrew it. Unknown
  /// `requestId`s are a no-op so a delivery loop can call this after a crash.
  Future<void> remove(PendingSendKey key, String requestId) => _transaction((doc) async {
    final entries = _entries(doc);
    final before = entries.length;
    entries.removeWhere((e) => _matches(e, key) && e['requestId'] == requestId);
    if (entries.length == before) return;
    doc['sends'] = entries;
    await _write(doc);
  });

  /// Counts a failed delivery attempt and records its stable [lastError] code.
  /// A send already taken or withdrawn is a no-op.
  Future<void> updateAttempt(PendingSendKey key, String requestId, {required String lastError}) async {
    if (!_within(lastError, _maxError)) throw _invalid;
    await _transaction((doc) async {
      final entries = _entries(doc);
      final index = entries.indexWhere((e) => _matches(e, key) && e['requestId'] == requestId);
      if (index < 0) return;
      final entry = entries[index];
      entry['attempts'] = _integer(entry['attempts'])! + 1;
      entry['lastError'] = lastError;
      doc['sends'] = entries;
      _fit(doc, entry);
      await _write(doc);
    });
  }

  /// Drops every pending send of [account] on sign-out, including other Hosts
  /// and sessions: another account must never deliver them.
  Future<void> clearAccount(String account) => _transaction((doc) async {
    final entries = _entries(doc);
    final before = entries.length;
    entries.removeWhere((e) => e['account'] == account);
    if (entries.length == before) return;
    doc['sends'] = entries;
    await _write(doc);
  });

  Future<T> _transaction<T>(FutureOr<T> Function(_Json) operation) {
    final key = _file.path;
    final result = (_queues[key] ?? Future<void>.value()).then((_) async => operation(await _read()));
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _queues[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return result;
  }

  Future<_Json> _read() async {
    RandomAccessFile? handle;
    try {
      handle = await _file.open();
      if (await handle.length() > _maxBytes) return _initial();
      final bytes = <int>[];
      while (bytes.length <= _maxBytes) {
        final chunk = await handle.read(math.min(65536, _maxBytes + 1 - bytes.length));
        if (chunk.isEmpty) break;
        bytes.addAll(chunk);
      }
      if (bytes.length > _maxBytes) return _initial();
      Object? value;
      try {
        value = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        return _initial();
      }
      if (value is! _Json || value['v'] != 1 || value['sends'] is! List) return _initial();
      // A partially written or older entry is dropped instead of failing the
      // whole outbox; its siblings are still deliverable.
      return {
        'v': 1,
        'sends': [
          for (final entry in value['sends']! as List)
            if (_validEntry(entry)) entry as _Json,
        ],
      };
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2 || (Platform.isWindows && error.osError?.errorCode == 3)) {
        return _initial();
      }
      throw _ioError;
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on FileSystemException {
          /* Best effort close. */
        }
      }
    }
  }

  Future<void> _write(_Json doc) async {
    final bytes = utf8.encode(jsonEncode(doc));
    if (bytes.length > _maxBytes) throw _tooLarge;
    final temporary = File.fromUri(_file.parent.uri.resolve('.pending-sends-${uuidV4()}.tmp'));
    var created = false;
    try {
      await _file.parent.create(recursive: true);
      await temporary.create(exclusive: true);
      created = true;
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(_file.path);
    } on FileSystemException {
      throw _ioError;
    } finally {
      try {
        if (created) await temporary.delete();
      } on FileSystemException {
        /* Missing after rename, or best effort cleanup. */
      }
    }
  }
}

_Json _initial() => {'v': 1, 'sends': <_Json>[]};

List<_Json> _entries(_Json doc) => (doc['sends']! as List).cast<_Json>().toList();

bool _matches(_Json entry, PendingSendKey key) =>
    entry['account'] == key.account && entry['host'] == key.host && entry['session'] == key.session;

_Json _entry(PendingSendKey key, PendingSend send) => {
  'account': key.account,
  'host': key.host,
  'session': key.session,
  'requestId': send.requestId,
  'text': send.text,
  'attachments': send.attachments,
  'createdAt': send.createdAt.millisecondsSinceEpoch,
  'attempts': send.attempts,
  'lastError': send.lastError,
};

PendingSend _send(_Json entry) => PendingSend(
  requestId: entry['requestId']! as String,
  text: entry['text']! as String,
  attachments: List.unmodifiable((entry['attachments']! as List).cast<String>()),
  createdAt: DateTime.fromMillisecondsSinceEpoch(_integer(entry['createdAt'])!),
  attempts: _integer(entry['attempts'])!,
  lastError: entry['lastError'] as String?,
);

int _byAge(_Json a, _Json b) {
  final byTime = _integer(a['createdAt'])!.compareTo(_integer(b['createdAt'])!);
  return byTime != 0 ? byTime : (a['requestId']! as String).compareTo(b['requestId']! as String);
}

int _bySendAge(PendingSend a, PendingSend b) {
  final byTime = a.createdAt.compareTo(b.createdAt);
  return byTime != 0 ? byTime : a.requestId.compareTo(b.requestId);
}

bool _validEntry(Object? value) {
  if (value is! _Json) return false;
  if (!_keys.every(value.containsKey) || !value.keys.every(_keys.contains)) return false;
  if (!_within(value['account'], _maxField) ||
      !_within(value['host'], _maxField) ||
      !_within(value['session'], _maxField) ||
      !_within(value['requestId'], _maxRequestId)) {
    return false;
  }
  final text = value['text'];
  if (text is! String || text.length > _maxText) return false;
  final attachments = value['attachments'];
  if (attachments is! List || attachments.length > _maxAttachments || !attachments.every((p) => _within(p, _maxPath))) {
    return false;
  }
  // `session/prompt` refuses empty content; such an entry could never deliver.
  if (text.trim().isEmpty && attachments.isEmpty) return false;
  final createdAt = _integer(value['createdAt']);
  if (createdAt == null || createdAt > _maxDateTime) return false;
  if (_integer(value['attempts']) == null) return false;
  final lastError = value['lastError'];
  return lastError == null || _within(lastError, _maxError);
}

bool _within(Object? value, int max) => value is String && value.length <= max && value.trim().isNotEmpty;

int? _integer(Object? value) => value is int && value >= 0 ? value : null;