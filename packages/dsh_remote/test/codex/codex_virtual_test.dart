import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import '../support/fake_remote.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late MemorySecretStore secrets;
  late RemoteAccount account;
  late DshClient client;
  late CodexVirtualHarness harness;

  setUp(() async {
    server = await FakeRemoteServer.start();
    host = await FakeRemoteHost.start(server);
    host.capabilities = [...host.capabilities, CodexVirtualHarness.codexAppCapability];
    // Catalog reads happen while the virtual client starts. A minimal CodeX
    // App Server answer is enough for the harness to reach ready state.
    host.codexAppHandlers['project/list'] = (params) => <String, Object?>{'data': <Object?>[]};
    host.codexAppHandlers['thread/list'] = (params) => <String, Object?>{'data': <Object?>[]};
    secrets = MemorySecretStore();
    account = RemoteAccount(
      secrets: secrets,
      serverUrl: server.url,
      loginPollInterval: const Duration(milliseconds: 20),
    );
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final target = (await account.listHosts()).single;
    client = await account.connectHost(target, muxOptions: fastMux, agent: RemoteAgent.codex);
    harness = (client.carrier as CodexVirtualCarrier).harness;
  });

  tearDown(() async {
    // A virtual carrier may still own a pending stream at this point; the
    // server/host teardown is what actually releases the tunnel.
    await account.close().timeout(const Duration(seconds: 1), onTimeout: () {});
    await host.close();
    await server.close();
  });

  test('commands/execute accepts submittedAttachments and names unsupported commands', () async {
    // The composer sends `submittedAttachments`; the old harness insisted on
    // `images` and failed every slash command before looking at the line.
    final result = await harness.dispatch('commands/execute', <String, Object?>{
      'agentId': 'codex:thread-1',
      'line': '/permission bogus',
      'submittedAttachments': <Object?>[],
    });
    expect(result, isA<RpcOk>());
    final value = (result as RpcOk).value! as Map<String, Object?>;
    final command = value['result']! as Map<String, Object?>;
    expect(command['kind'], 'error');
    expect(command['text'], contains('unknown preset'));

    final unsupported = await harness.dispatch('commands/execute', <String, Object?>{
      'agentId': 'codex:thread-1',
      'line': '/plan',
      'submittedAttachments': <Object?>[],
    });
    expect(unsupported, isA<RpcError>());
    expect((unsupported as RpcError).error.code, 'FEATURE_NOT_SUPPORTED');
    expect(unsupported.error.message, contains('/plan'));

    // The older `images` spelling remains valid.
    final legacy = await harness.dispatch('commands/execute', <String, Object?>{
      'agentId': 'codex:thread-1',
      'line': '/permission bogus',
      'images': <Object?>[],
    });
    expect(legacy, isA<RpcOk>());
  });

  test('the real client sends submittedAttachments, with images as fallback', () async {
    // `commands/execute` is a virtual endpoint: it never reaches
    // `codex.app.call`, so observe the exact client payload at dispatch and
    // the App Server call at codexAppHandlers separately.
    final dispatched = <Map<String, Object?>>[];
    harness.onDispatch = (endpoint, payload) {
      if (endpoint == 'commands/execute') dispatched.add(Map<String, Object?>.from(payload));
    };
    final resumed = <Map<String, Object?>>[];
    host.codexAppHandlers['thread/resume'] = (params) {
      resumed.add(params);
      return <String, Object?>{'sandbox': 'workspace-write', 'approvalPolicy': 'on-request'};
    };

    Future<String> commandText({
      String line = '/permission bogus',
      List<Object?>? submitted,
      List<Object?>? images,
    }) async {
      final args = <String, Object?>{'agentId': 'codex:thread-1', 'line': line};
      if (submitted != null) args['submittedAttachments'] = submitted;
      if (images != null) args['images'] = images;
      final value = await client.rpc.call('commands/execute', args) as Map<String, Object?>;
      return (value['result']! as Map<String, Object?>)['text']! as String;
    }

    expect(await commandText(submitted: <Object?>[<String, Object?>{'path': '/tmp/a.png'}]),
        contains('do not accept attachments'));
    expect(dispatched.single['submittedAttachments'], <Object?>[<String, Object?>{'path': '/tmp/a.png'}]);

    expect(await commandText(submitted: <Object?>[], images: <Object?>['x']), contains('unknown preset'),
        reason: 'submittedAttachments takes priority over the legacy field');
    expect(await commandText(images: <Object?>['x']), contains('do not accept attachments'),
        reason: 'the legacy field is still accepted');
    expect(await commandText(), contains('unknown preset'), reason: 'neither field means no attachments');

    expect(await commandText(line: '/permission workspace-write', submitted: <Object?>[]),
        contains('preset workspace-write'));
    expect(resumed, hasLength(1));
    expect(resumed.single['permissionPreset'], 'workspace-write');
  });

  test('session/prompt does not forward cwd or permissionPreset to CodeX', () async {
    Map<String, Object?>? sent;
    host.codexAppHandlers['turn/start'] = (params) {
      sent = params;
      return <String, Object?>{};
    };

    const sessionId = 'codex:thread-2';
    harness.selectedModels[sessionId] = <String, Object?>{
      'provider': 'codex',
      'model': 'gpt-5',
      'reasoningEffort': 'medium',
    };
    harness.blankThreads.add('thread-2');

    final result = await client.rpc.call('session/prompt', <String, Object?>{
      'sessionId': sessionId,
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': 'hello'},
      ],
    });
    expect(result, isA<Map<String, Object?>>());
    expect(sent, isNotNull);
    final params = sent!;
    expect(params, isNot(containsPair('cwd', anything)));
    expect(params, isNot(containsPair('permissionPreset', anything)));
    expect(params['threadId'], 'thread-2');
    expect(params['model'], 'gpt-5');
    expect(params['effort'], 'medium');
  });
}
