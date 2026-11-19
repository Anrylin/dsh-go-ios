import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'account_state.dart';
import 'attachments.dart';

/// Storage seam for pending sends; tests can replace it with a temp directory.
final pendingSendDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory(
        '${(await getApplicationSupportDirectory()).path}/pending-sends',
      ),
);

/// The durable outbox, plus the draft bytes its attachment paths point at.
/// A login that goes away must not leave another account's sends behind.
final pendingSendOutboxProvider = FutureProvider<PendingOutbox>((ref) async {
  ref.watch(accountProvider.select((s) => s.profile?.id));
  final directoryFuture = ref.watch(pendingSendDirectoryProvider)();
  ref.listen(accountProvider.select((s) => s.profile?.id), (previous, next) {
    if (previous != null && previous != next) {
      directoryFuture
          .then(
            (directory) => PendingOutbox(directory).clearAccount(previous),
          )
          .ignore();
    }
  });
  return PendingOutbox(await directoryFuture);
});

/// Keeps attachment bytes alive until the Host accepts the prompt: the picker
/// hands over in-memory bytes, so a restart could not read them from their
/// original source. Files live in `drafts/<account>/<requestId>/` and are
/// removed together with their outbox entry.
final class PendingOutbox {
  PendingOutbox(this.root) : store = PendingSendStore(directory: root);

  /// Test seam for widget tests, where native file I/O cannot settle inside a
  /// fake-async pump. Production always uses the file-backed constructor.
  PendingOutbox.withStore(this.root, this.store);

  final Directory root;
  final PendingSendStore store;

  int get maxPerSession => store.maxPerSession;

  /// Draft bytes kept per queued send. The queue itself only bounds JSON size;
  /// attachment bytes are the phone's disk, so a huge pick is sent live and is
  /// simply not made durable (a replay would lose part of it otherwise).
  static const maxDraftBytes = 24 * 1024 * 1024;

  static String _part(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Directory _drafts(PendingSendKey key, String requestId) => Directory(
    '${root.path}/drafts/${_part(key.account)}/${_part(requestId)}',
  );

  /// Writes the draft files first, then the queue entry that references them.
  /// Returns the entry the per-session cap dropped, if any.
  Future<PendingSend?> add(
    PendingSendKey key,
    PendingSend send,
    List<DraftAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return store.add(key, send);
    final total = attachments.fold<int>(0, (sum, attachment) => sum + attachment.bytes.length);
    if (total > maxDraftBytes) {
      // Too much to keep twice on disk: this send still goes out now, but it is
      // not replayable after a restart, and no partial copy is kept.
      return null;
    }
    final drafts = _drafts(key, send.requestId);
    await drafts.create(recursive: true);
    final paths = <String>[];
    for (var i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      final path = '${drafts.path}/$i-${_part(attachment.name)}';
      await File(path).writeAsBytes(attachment.bytes, flush: true);
      paths.add(path);
    }
    try {
      final dropped = await store.add(
        key,
        PendingSend(
          requestId: send.requestId,
          text: send.text,
          createdAt: send.createdAt,
          attachments: paths,
        ),
      );
      if (dropped != null) await _discard(dropped);
      return dropped;
    } catch (_) {
      await _discardDir(drafts);
      rethrow;
    }
  }

  Future<void> remove(PendingSendKey key, String requestId) async {
    final targets = (await store.load(key))
        .where((send) => send.requestId == requestId);
    await store.remove(key, requestId);
    for (final send in targets) {
      await _discard(send);
    }
  }

  Future<void> clearAccount(String account) async {
    await store.clearAccount(account);
    final drafts = Directory('${root.path}/drafts/${_part(account)}');
    await _discardDir(drafts);
  }

  /// The bytes to send again after a restart. Image media types are sniffed
  /// from the same bytes the composer sniffed when the draft was picked.
  Future<List<DraftAttachment>> attachmentsFor(PendingSend send) async {
    final restored = <DraftAttachment>[];
    for (final path in send.attachments) {
      final bytes = await File(path).readAsBytes();
      final name = path
          .split(RegExp(r'[\\/]'))
          .last
          .replaceFirst(RegExp(r'^\d+-'), '');
      restored.add(DraftAttachment.sniff(name, bytes));
    }
    return restored;
  }

  Future<void> _discard(PendingSend send) async {
    for (final path in {
      for (final attachment in send.attachments) File(attachment).parent.path,
    }) {
      await _discardDir(Directory(path));
    }
  }

  Future<void> _discardDir(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
