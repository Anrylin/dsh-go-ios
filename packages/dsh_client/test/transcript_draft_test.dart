import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TranscriptCache cache;
  var clock = 1000;
  int now() => clock++;

  setUp(() {
    clock = 1000;
    directory = Directory.systemTemp.createTempSync('transcript_draft_test');
    cache = TranscriptCache(directory: directory, nowMilliseconds: now);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  CachedDraft draft({
    String account = 'acc',
    String hostId = 'local',
    String sessionId = 's1',
    int cursor = 4,
    int revision = 3,
    List<ChatItem>? items,
  }) {
    return CachedDraft(
      account: account,
      hostId: hostId,
      sessionId: sessionId,
      cursor: cursor,
      revision: revision,
      title: 'First chat',
      hasMoreHistory: true,
      items: items ?? sampleRows(),
    );
  }

  test('a live reply survives a reload that loses the window', () async {
    await cache.saveDraft(draft());
    expect(await cache.load(hostId: 'local', sessionId: 's1', account: 'acc'), isNull);

    final loaded = await cache.loadDraft(hostId: 'local', sessionId: 's1', account: 'acc');
    expect(loaded, isNotNull);
    expect(loaded!.cursor, 4);
    expect(loaded.revision, 3);
    expect(loaded.title, 'First chat');
    expect(loaded.hasMoreHistory, isTrue);
    expect(loaded.items, hasLength(4));
    expect(loaded.toJson(), equals(draft().toJson()));
  });

  test('the sidecar accepts streaming rows a window refuses', () async {
    final rows = [
      UserChatItem(
        seq: 1,
        time: DateTime.fromMillisecondsSinceEpoch(1),
        text: 'hi',
        images: const [],
        files: const [],
      ),
      AssistantChatItem(id: 'd1', rowKey: 'm1.1', text: 'partial', reasoning: '', streaming: true),
      ToolChatItem(
        callId: 'c1',
        name: 'edit',
        arguments: '{"path":',
        status: ToolStatus.running,
      ),
    ];
    // A durable window keeps only the rows it can rebuild; the sidecar keeps
    // the live assistant and tool rows.
    await cache.save(
      CachedTranscript(account: 'acc', hostId: 'local', sessionId: 's1', cursor: 1, items: rows),
    );
    final window = await cache.load(hostId: 'local', sessionId: 's1', account: 'acc');
    expect(window, isNotNull);
    expect(window!.items, hasLength(1));
    expect(window.items.single, isA<UserChatItem>());

    await cache.saveDraft(draft(items: rows));
    final loaded = await cache.loadDraft(hostId: 'local', sessionId: 's1', account: 'acc');
    expect(loaded, isNotNull);
    expect(loaded!.items, hasLength(3));
    final assistant = loaded.items[1] as AssistantChatItem;
    expect(assistant.streaming, isTrue);
    expect(assistant.seq, isNull);
    expect(assistant.rowKey, 'm1.1');
    expect((loaded.items[2] as ToolChatItem).status, ToolStatus.running);
  });

  test('an approval request is restored as a running tool, never answerable', () async {
    final rows = [
      ToolChatItem(
        callId: 'c1',
        name: 'edit',
        arguments: '{}',
        status: ToolStatus.awaitingApproval,
        pendingApproval: ApprovalRequest(
          eventId: 'e1',
          sessionId: 's1',
          toolName: 'edit',
          callId: 'c1',
        ),
      ),
    ];
    await cache.saveDraft(draft(items: rows, cursor: -1));
    final loaded = await cache.loadDraft(hostId: 'local', sessionId: 's1', account: 'acc');
    expect(loaded, isNotNull);
    final tool = loaded!.items.single as ToolChatItem;
    expect(tool.status, ToolStatus.running);
    expect(tool.pendingApproval, isNull);
  });

  test('a sidecar is isolated by account and host, and clearAccount removes it', () async {
    await cache.saveDraft(draft(account: 'acc-a', sessionId: 'a1'));
    await cache.saveDraft(draft(account: 'acc-b', sessionId: 'a2'));
    await cache.saveDraft(draft(account: '', sessionId: 'a3'));
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a1', account: 'acc-a'), isNotNull);
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a1', account: null), isNotNull);
    expect(await cache.loadDraft(hostId: 'relay', sessionId: 'a1', account: 'acc-a'), isNull);

    await cache.clearAccount('acc-a');
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a1', account: null), isNull);
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a2', account: null), isNotNull);
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a3', account: null), isNotNull);

    // Reading a sidecar under a different account discards the stale file.
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a2', account: 'acc-a'), isNull);
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a2', account: null), isNull);
  });

  test('clearAll drops sidecars with their windows', () async {
    await cache.saveDraft(draft());
    await cache.save(
      CachedTranscript(account: 'acc', hostId: 'local', sessionId: 's1', cursor: 1, items: sampleRows()),
    );
    await cache.clearAll();
    expect(directory.existsSync(), isFalse);
  });

  test('an oversized or untrustworthy sidecar is not kept', () async {
    final small = TranscriptCache(directory: directory, maxEntryBytes: 128, nowMilliseconds: now);
    await small.saveDraft(draft(sessionId: 'big'));
    expect(await small.loadDraft(hostId: 'local', sessionId: 'big', account: 'acc'), isNull);

    await cache.saveDraft(draft(sessionId: 'bad'));
    final file = directory
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.draft.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    json['v'] = transcriptDraftVersion + 1;
    await file.writeAsString(jsonEncode(json));
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'bad', account: 'acc'), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('a sidecar past its cursor or with an unencodable row is refused', () async {
    final past = draft(cursor: 1, items: sampleRows());
    expect(CachedDraft.fromJson(past.toJson()), isNull);

    final broken = draft(
      cursor: -1,
      items: [
        ToolChatItem(
          callId: 'c1',
          name: 'read',
          arguments: '{}',
          status: ToolStatus.succeeded,
          resultParts: [UnknownPart('hologram', const {})],
        ),
      ],
    );
    expect(broken.toJson(), isNull);
    await cache.saveDraft(broken);
    expect(await cache.loadDraft(hostId: 'local', sessionId: 's1', account: 'acc'), isNull);
  });

  test('clearDraft leaves another account sidecar under the same key alone', () async {
    await cache.saveDraft(draft(account: 'acc-a', sessionId: 'a1'));
    await cache.clearDraft(hostId: 'local', sessionId: 'a1', account: 'acc-b');
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a1', account: null), isNotNull);

    await cache.clearDraft(hostId: 'local', sessionId: 'a1', account: 'acc-a');
    expect(await cache.loadDraft(hostId: 'local', sessionId: 'a1', account: null), isNull);
  });

  test('a crashed draft temp file is pruned by the next write', () async {
    await cache.saveDraft(draft(sessionId: 's1'));
    final stored = directory.listSync(recursive: true).whereType<File>().singleWhere(
          (f) => f.path.endsWith('.draft.json'),
        );
    final residue = File('${stored.path}.tmp-deadbeef');
    await residue.writeAsString('crashed mid-write');

    await cache.saveDraft(draft(sessionId: 's2'));
    expect(residue.existsSync(), isFalse, reason: 'no loader reads .tmp-uuid files');
    expect(await cache.loadDraft(hostId: 'local', sessionId: 's1', account: 'acc'), isNotNull);
  });

  test('a restored draft still counts as live until the snapshot settles it', () {
    final restored = ChatTranscript()
      ..seedItems([
        AssistantChatItem(id: 'r', text: 'partial', reasoning: '', streaming: true),
        ToolChatItem(callId: 't', name: 'edit', arguments: '{}', status: ToolStatus.running),
      ]);
    expect(restored.hasLiveDraft, isTrue, reason: 'seeded live rows must keep the sidecar alive');

    final settled = ChatTranscript()
      ..seedItems([AssistantChatItem(id: 'r', text: 'done', reasoning: '', streaming: false)]);
    expect(settled.hasLiveDraft, isFalse);

    final committed = ChatTranscript()
      ..seedItems([
        AssistantChatItem(id: 'r', seq: 2, text: 'done', reasoning: '', streaming: true),
        ToolChatItem(callId: 't', name: 'edit', arguments: '{}', status: ToolStatus.running, seq: 3),
      ]);
    expect(
      committed.hasLiveDraft,
      isFalse,
      reason: 'a durable row keeps its seq, so a running status belongs to the snapshot, not a sidecar',
    );
  });
}

List<ChatItem> sampleRows() => [
  UserChatItem(
    seq: 1,
    time: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    text: 'look at this',
    images: const [],
    files: const [],
  ),
  AssistantChatItem(
    id: 'a2',
    rowKey: 'm1.1',
    seq: 2,
    time: DateTime.fromMillisecondsSinceEpoch(1700000001000),
    text: 'Done.',
    reasoning: 'Checked the file.',
  ),
  ToolChatItem(
    callId: 'c1',
    name: 'read',
    arguments: '{"path":"x.txt"}',
    status: ToolStatus.succeeded,
    seq: 3,
  ),
  NoticeChatItem(seq: 4, kind: 'error', text: 'The turn failed'),
];
