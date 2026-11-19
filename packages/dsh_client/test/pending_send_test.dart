import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const accountA = 'acct-a';
const accountB = 'acct-b';
const host = 'host-1';
const session = 'session-1';

File storeFile(Directory dir) => File('${dir.path}/pending-sends.json');
DateTime at(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);

PendingSendKey keyOf(String sessionId, {String account = accountA}) =>
    PendingSendKey(account: account, host: host, session: sessionId);

PendingSend sendOf(
  String requestId, {
  String text = '合成消息',
  DateTime? createdAt,
  List<String> attachments = const [],
  int attempts = 0,
  String? lastError,
}) => PendingSend(
  requestId: requestId,
  text: text,
  createdAt: createdAt ?? at(1000),
  attachments: attachments,
  attempts: attempts,
  lastError: lastError,
);

void main() {
  late Directory dir;
  late PendingSendStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pending-send-test-');
    store = PendingSendStore(directory: dir);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('add, load and remove round-trip one session', () async {
    await store.add(keyOf(session), sendOf('r1', text: '第一条'));
    await store.add(
      keyOf(session),
      sendOf('r2', text: '第二条', attachments: const ['/files/a.png'], attempts: 1, lastError: 'dsh/transport'),
    );
    final loaded = await store.load(keyOf(session));
    expect(loaded.map((s) => s.requestId), ['r1', 'r2']);
    expect(loaded[0].text, '第一条');
    expect(loaded[1].attachments, ['/files/a.png']);
    expect(loaded[1].createdAt, at(1000));
    expect(loaded[1].attempts, 1);
    expect(loaded[1].lastError, 'dsh/transport');
    expect(storeFile(dir).existsSync(), isTrue);

    await store.remove(keyOf(session), 'r1');
    expect((await store.load(keyOf(session)).then((s) => s.single.requestId)), 'r2');
    // A delivery loop may call remove again after a crash: it is a no-op.
    await store.remove(keyOf(session), 'r1');
    expect((await store.load(keyOf(session)).then((s) => s.single.requestId)), 'r2');
  });

  test('keeps at most 20 sends per session and drops the oldest', () async {
    expect(store.maxPerSession, 20);
    for (var i = 0; i < 20; i++) {
      expect(await store.add(keyOf(session), sendOf('r$i', createdAt: at(1000 + i))), isNull);
    }
    expect(await store.add(keyOf(session), sendOf('r20', createdAt: at(1020))).then((s) => s?.requestId), 'r0');
    var loaded = await store.load(keyOf(session));
    expect(loaded, hasLength(20));
    expect(loaded.first.requestId, 'r1');
    expect(loaded.last.requestId, 'r20');

    expect(await store.add(keyOf(session), sendOf('r21', createdAt: at(1021))).then((s) => s?.requestId), 'r1');
    loaded = await store.load(keyOf(session));
    expect(loaded.first.requestId, 'r2');
    expect(loaded.last.requestId, 'r21');

    // The cap is per session: another session still has room.
    expect(await store.add(keyOf('session-2'), sendOf('other')), isNull);
    expect((await store.load(keyOf('session-2')).then((s) => s.single.requestId)), 'other');
  });

  test('a corrupt file reads as empty and the next add replaces it', () async {
    await storeFile(dir).writeAsString('{not json');
    expect(await store.load(keyOf(session)), isEmpty);
    await store.add(keyOf(session), sendOf('r1'));
    expect((await store.load(keyOf(session)).then((s) => s.single.requestId)), 'r1');

    await storeFile(dir).writeAsString(jsonEncode({'v': 2, 'sends': <Object?>[]}));
    expect(await store.load(keyOf(session)), isEmpty);
  });

  test('drops only the invalid entries of an otherwise readable file', () async {
    final doc = {
      'v': 1,
      'sends': [
        {
          'account': accountA,
          'host': host,
          'session': session,
          'requestId': 'r1',
          'text': '好的',
          'attachments': <String>[],
          'createdAt': 1000,
          'attempts': 0,
          'lastError': null,
        },
        {'requestId': 'r2', 'text': '缺字段'},
        {
          'account': accountA,
          'host': host,
          'session': session,
          'requestId': 'r3',
          'text': '   ',
          'attachments': <String>[],
          'createdAt': 1000,
          'attempts': 0,
          'lastError': null,
        },
      ],
    };
    await storeFile(dir).writeAsString(jsonEncode(doc));
    expect((await store.load(keyOf(session)).then((s) => s.single.requestId)), 'r1');
  });

  test('clearAccount keeps other accounts and sessions', () async {
    await store.add(keyOf(session), sendOf('r1'));
    await store.add(keyOf(session, account: accountB), sendOf('r2'));
    await store.add(keyOf('session-2', account: accountB), sendOf('r3'));
    await store.clearAccount(accountA);
    expect(await store.load(keyOf(session)), isEmpty);
    expect((await store.load(keyOf(session, account: accountB)).then((s) => s.single.requestId)), 'r2');
    expect((await store.load(keyOf('session-2', account: accountB)).then((s) => s.single.requestId)), 'r3');
  });

  test('loads in createdAt order, whatever the insertion order', () async {
    await store.add(keyOf(session), sendOf('c', createdAt: at(3000)));
    await store.add(keyOf(session), sendOf('a', createdAt: at(1000)));
    await store.add(keyOf(session), sendOf('b', createdAt: at(2000)));
    expect((await store.load(keyOf(session))).map((s) => s.requestId), ['a', 'b', 'c']);
  });

  test('a new store instance over the same directory reads the sends back', () async {
    await store.add(keyOf(session), sendOf('r1', text: '重启前的话', attachments: const ['/files/report.pdf']));
    final restarted = PendingSendStore(directory: dir);
    final loaded = (await restarted.load(keyOf(session))).single;
    expect(loaded.requestId, 'r1');
    expect(loaded.text, '重启前的话');
    expect(loaded.attachments, ['/files/report.pdf']);
    expect(loaded.createdAt, at(1000));
    expect(loaded.attempts, 0);
    expect(loaded.lastError, isNull);

    await restarted.remove(keyOf(session), 'r1');
    expect(await store.load(keyOf(session)), isEmpty);
  });

  test('re-adding the same requestId rewrites it and keeps its place', () async {
    await store.add(keyOf(session), sendOf('r1', text: '原文', createdAt: at(1000)));
    expect(await store.add(keyOf(session), sendOf('r1', text: '改后的话', createdAt: at(9000), attempts: 3)), isNull);
    final loaded = (await store.load(keyOf(session))).single;
    expect(loaded.text, '改后的话');
    expect(loaded.createdAt, at(1000));
    // The stored attempt history is the truth, not the caller's copy.
    expect(loaded.attempts, 0);
    expect(loaded.lastError, isNull);
  });

  test('updateAttempt counts the failure and keeps the send queued', () async {
    await store.add(keyOf(session), sendOf('r1', text: '重试的话'));
    await store.updateAttempt(keyOf(session), 'r1', lastError: 'dsh/transport-socket');
    var loaded = (await store.load(keyOf(session))).single;
    expect(loaded.attempts, 1);
    expect(loaded.lastError, 'dsh/transport-socket');
    await store.updateAttempt(keyOf(session), 'r1', lastError: 'dsh/transport-socket');
    loaded = (await store.load(keyOf(session))).single;
    expect(loaded.attempts, 2);
    expect(loaded.text, '重试的话');

    // A send already taken or withdrawn is a no-op.
    await store.updateAttempt(keyOf(session), 'missing', lastError: 'dsh/io');
    expect((await store.load(keyOf(session))).single.attempts, 2);
  });

  test('refuses empty content and an outbox over the size cap', () async {
    await expectLater(
      store.add(keyOf(session), sendOf('r1', text: '   ')),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'pending-send/invalid-request')),
    );
    await expectLater(
      store.add(keyOf(session), sendOf('r2', text: 'x' * (5 * 1024 * 1024))),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'pending-send/too-large')),
    );
    expect(await store.load(keyOf(session)), isEmpty);
    expect(storeFile(dir).existsSync(), isFalse);
  });
}
