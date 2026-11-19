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
    directory = Directory.systemTemp.createTempSync('transcript_cache_test');
    cache = TranscriptCache(directory: directory, nowMilliseconds: now);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  CachedTranscript window(String sessionId, {String account = 'acc', int cursor = 4}) {
    return CachedTranscript(
      account: account,
      hostId: 'local',
      sessionId: sessionId,
      cursor: cursor,
      title: 'First chat',
      hasMoreHistory: true,
      items: sampleRows(),
    );
  }

  test('a window round-trips every row it can rebuild', () async {
    final saved = window('s1');
    await cache.save(saved);
    final loaded = await cache.load(hostId: 'local', sessionId: 's1', account: 'acc');
    expect(loaded, isNotNull);
    expect(loaded!.cursor, 4);
    expect(loaded.title, 'First chat');
    expect(loaded.hasMoreHistory, isTrue);
    expect(loaded.account, 'acc');
    expect(loaded.items, hasLength(4));
    expect(loaded.toJson(), equals(saved.toJson()));
  });

  test('a streaming draft and pending approvals are not cached', () async {
    final saved = CachedTranscript(
      account: 'acc',
      hostId: 'local',
      sessionId: 's2',
      cursor: 2,
      items: [
        UserChatItem(
          seq: 1,
          time: DateTime.fromMillisecondsSinceEpoch(1),
          text: 'hi',
          images: const [],
          files: const [],
        ),
        AssistantChatItem(id: 'd1', text: 'partial', reasoning: '', streaming: true, seq: 2),
        ToolChatItem(
          callId: 'c1',
          name: 'edit',
          arguments: '{}',
          status: ToolStatus.awaitingApproval,
          seq: 2,
          pendingApproval: ApprovalRequest(eventId: 'e1', sessionId: 's2', toolName: 'edit', callId: 'c1'),
        ),
      ],
    );
    await cache.save(saved);
    final loaded = await cache.load(hostId: 'local', sessionId: 's2', account: 'acc');
    expect(loaded, isNotNull);
    expect(loaded!.items, hasLength(2));
    expect(loaded.items.last, isA<ToolChatItem>());
    expect((loaded.items.last as ToolChatItem).status, ToolStatus.running);
    expect((loaded.items.last as ToolChatItem).pendingApproval, isNull);
  });

  test('a draft-only window leaves no file behind', () async {
    await cache.save(
      CachedTranscript(
        account: 'acc',
        hostId: 'local',
        sessionId: 'draft',
        cursor: 1,
        items: [AssistantChatItem(id: 'd1', text: 'partial', reasoning: '', streaming: true, seq: 1)],
      ),
    );
    expect(await cache.load(hostId: 'local', sessionId: 'draft', account: 'acc'), isNull);
  });

  test('a row holding an unknown part refuses the whole window', () async {
    final saved = CachedTranscript(
      account: 'acc',
      hostId: 'local',
      sessionId: 's3',
      cursor: 1,
      items: [
        ToolChatItem(
          callId: 'c1',
          name: 'read',
          arguments: '{}',
          status: ToolStatus.succeeded,
          seq: 1,
          resultParts: [UnknownPart('hologram', const {})],
        ),
      ],
    );
    await cache.save(saved);
    expect(await cache.load(hostId: 'local', sessionId: 's3', account: 'acc'), isNull);
  });

  test('nine windows keep only the eight most recently used', () async {
    for (var i = 1; i <= 9; i++) {
      await cache.save(window('s$i'));
    }
    final files = directory.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json'));
    expect(files, hasLength(8));
    final oldest = await cache.load(hostId: 'local', sessionId: 's1', account: 'acc');
    expect(oldest, isNull);
    // Reading a window makes it the most recently used one.
    expect(await cache.load(hostId: 'local', sessionId: 's2', account: 'acc'), isNotNull);
    await cache.save(window('s10'));
    expect(await cache.load(hostId: 'local', sessionId: 's2', account: 'acc'), isNotNull);
    expect(
      await cache.load(hostId: 'local', sessionId: 's3', account: 'acc'),
      isNull,
      reason: 's3 became the oldest',
    );
  });

  test('an oversized window is not written', () async {
    final small = TranscriptCache(directory: directory, maxEntryBytes: 128, nowMilliseconds: now);
    final saved = CachedTranscript(
      account: 'acc',
      hostId: 'local',
      sessionId: 'big',
      cursor: 1,
      items: [
        UserChatItem(
          seq: 1,
          time: DateTime.fromMillisecondsSinceEpoch(1),
          text: 'x' * 512,
          images: const [],
          files: const [],
        ),
      ],
    );
    await small.save(saved);
    expect(await small.load(hostId: 'local', sessionId: 'big', account: 'acc'), isNull);
  });

  test('a corrupt file is a miss and is dropped', () async {
    await cache.save(window('s4'));
    final file = directory.listSync(recursive: true).whereType<File>().singleWhere((f) => f.path.endsWith('.json'));
    await file.writeAsString('{not json');
    expect(await cache.load(hostId: 'local', sessionId: 's4', account: 'acc'), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('another shape version is dropped', () async {
    await cache.save(window('s5'));
    final file = directory.listSync(recursive: true).whereType<File>().singleWhere((f) => f.path.endsWith('.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    json['v'] = transcriptCacheVersion + 1;
    await file.writeAsString(jsonEncode(json));
    expect(await cache.load(hostId: 'local', sessionId: 's5', account: 'acc'), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('a window from another account is stale', () async {
    await cache.save(window('s6', account: 'acc-a'));
    expect(await cache.load(hostId: 'local', sessionId: 's6', account: null), isNotNull);
    expect(await cache.load(hostId: 'local', sessionId: 's6', account: 'acc-b'), isNull);
  });

  test('rows past the window cursor are rejected', () async {
    final saved = CachedTranscript(
      account: 'acc',
      hostId: 'local',
      sessionId: 's7',
      cursor: 2,
      items: [
        UserChatItem(
          seq: 1,
          time: DateTime.fromMillisecondsSinceEpoch(1),
          text: 'hi',
          images: const [],
          files: const [],
        ),
        UserChatItem(
          seq: 3,
          time: DateTime.fromMillisecondsSinceEpoch(5),
          text: 'later',
          images: const [],
          files: const [],
        ),
      ],
    );
    expect(saved.toJson(), isNotNull);
    final decoded = CachedTranscript.fromJson(saved.toJson());
    expect(decoded, isNull);
  });

  test('clearAccount keeps the other windows', () async {
    await cache.save(window('a1', account: 'acc-a'));
    await cache.save(window('a2', account: 'acc-b'));
    await cache.save(window('a3', account: ''));
    await cache.clearAccount('acc-a');
    expect(await cache.load(hostId: 'local', sessionId: 'a1', account: 'acc-a'), isNull);
    expect(await cache.load(hostId: 'local', sessionId: 'a2', account: 'acc-b'), isNotNull);
    expect(await cache.load(hostId: 'local', sessionId: 'a3', account: null), isNotNull);
  });

  test('clearAll removes the cache directory', () async {
    await cache.save(window('s8'));
    await cache.clearAll();
    expect(directory.existsSync(), isFalse);
  });

  test('a seeded transcript shows the cached window until the snapshot replaces it', () {
    final transcript = ChatTranscript();
    transcript.seedItems(sampleRows().whereType<UserChatItem>().toList(), title: 'Cached');
    expect(transcript.items, hasLength(1));
    expect(transcript.items.single, isA<UserChatItem>());
    expect(transcript.cursor, -1, reason: 'only the Host owns the cursor');
    expect(transcript.hasMoreHistory, isFalse);
    expect(transcript.title, 'Cached');

    final live = UserMessageEvent(
      1,
      DateTime.fromMillisecondsSinceEpoch(9),
      const {},
      message: Message(
        id: 'm1',
        role: MessageRole.user,
        parts: const [TextPart('live')],
        source: MessageSource('user', {}),
      ),
    );
    transcript.apply(
      SessionSnapshotEvent(
        sessionId: 's',
        header: SessionHeader(id: 's', version: 1, createdAt: DateTime.fromMillisecondsSinceEpoch(0), isSeeded: false),
        cursor: 1,
        events: [live],
        hasMore: false,
        projections: SessionProjections.empty,
        assistantRevision: null,
      ),
    );
    expect(transcript.items, hasLength(1));
    expect((transcript.items.single as UserChatItem).text, 'live');
    expect(transcript.title, isNull);
  });
}

List<ChatItem> sampleRows() => [
  UserChatItem(
    seq: 1,
    time: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    text: 'look at this',
    images: const [
      ImageAttachment(attachmentId: 'img-1', mediaType: 'image/png', bytes: 1234, width: 10, height: 20, name: 'a.png'),
    ],
    files: const [FileAttachment(attachmentId: 'f1', name: 'x.txt', bytes: 5)],
    requestId: 'r1',
  ),
  AssistantChatItem(
    id: 'a2',
    rowKey: 'm1.1',
    seq: 2,
    time: DateTime.fromMillisecondsSinceEpoch(1700000001000),
    text: 'Done.',
    reasoning: 'Checked the file.',
    interrupted: true,
    usage: const TokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12, cacheReadTokens: 4),
    model: 'deepseek-v4',
  ),
  ToolChatItem(
    callId: 'c1',
    name: 'read',
    arguments: '{"path":"x.txt"}',
    status: ToolStatus.failed,
    seq: 3,
    resultParts: const [
      TextPart('missing'),
      ImagePart(_thumb, offloaded: false),
      FilePart(FileAttachment(attachmentId: 'f2', name: 'out.txt')),
    ],
    failure: const ToolFailure('read', 'E_NOENT', 'No such file'),
    approvalOutcome: ApprovalOutcome.rejected,
    meta: const {'diff': 'x'},
  ),
  NoticeChatItem(
    seq: 4,
    kind: 'error',
    text: 'The turn failed',
    failure: const LlmFailure(message: 'boom', code: 'E_PROVIDER', status: 503),
  ),
];

const _thumb = ImageAttachment(attachmentId: 'img-2', mediaType: 'image/jpeg', bytes: 99);
