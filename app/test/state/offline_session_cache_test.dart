import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/state/offline_session_cache.dart';
import 'package:dsh_app/state/read_list_data.dart';

void main() {
  test('offline session list survives a cold start', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-offline-cache-');
    addTearDown(() async {
      await dir.delete(recursive: true);
    });

    final first = OfflineSessionCache(directory: dir);
    await first.load();
    first.remember(
      hostId: 'host-1',
      workspace: 'all',
      sessions: CachedSessions(
        sessions: [
          SessionSummary(
            sessionId: 's1',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1234),
            running: false,
            blank: false,
            agentAvailable: false,
            projections: const SessionProjections(-1, <String, Object?>{'title': 'Cached chat'}),
          ),
        ],
        bots: const [],
        workspaceVersion: null,
        scoped: false,
        workspaceLabel: null,
      ),
    );
    // remember() flushes asynchronously; wait for that write before reopening.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final second = OfflineSessionCache(directory: dir);
    await second.load();
    final restored = second.read('host-1', 'all');
    expect(restored, isNotNull);
    expect(restored!.sessions, hasLength(1));
    expect(restored.sessions.single.sessionId, 's1');
    expect(restored.sessions.single.title, 'Cached chat');
  });
}
