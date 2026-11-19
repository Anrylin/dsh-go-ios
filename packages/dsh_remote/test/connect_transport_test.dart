// Bounded direct attempt: a direct path that opens inside the head start keeps
// the only connection, a stalled one hands over to the Relay before its ICE
// deadline, and the transport that carried the last session is remembered until
// an attempt disproves it.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';
import 'support/fake_rtc.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

void main() {
  group('bounded direct attempt', () {
    late FakeRemoteServer server;
    late FakeRemoteHost host;
    late FakeRtcNetwork network;
    late RemoteAccount account;
    final fallbacks = <String>[];

    RemoteAccount build({Duration directTimeout = const Duration(milliseconds: 300), Duration? directHeadStart}) =>
        RemoteAccount(
          secrets: MemorySecretStore(),
          serverUrl: server.url,
          peerConnector: network.connector,
          onDirectFallback: fallbacks.add,
          directTimeout: directTimeout,
          directHeadStart: directHeadStart ?? const Duration(seconds: 2),
        );

    setUp(() async {
      server = await FakeRemoteServer.start();
      server.webrtc = true;
      // A STUN-only list keeps the direct stage real and the TURN stage without
      // credentials, so a stalled LAN negotiation is the only slow path.
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478'],
        },
      ];
      network = FakeRtcNetwork();
      host = await FakeRemoteHost.start(server)
        ..webrtc = true
        ..rtcNetwork = network;
      await host.goOffline();
      await host.goOnline();
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      };
      fallbacks.clear();
      account = build();
    });

    tearDown(() async {
      expect(server.protocolErrors, isEmpty, reason: 'the client never violated the Control protocol');
      await account.close();
      await host.close();
      await server.close();
    });

    Future<DshClient> connect() async {
      await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
      return account.connectHost((await account.listHosts()).single, muxOptions: fastMux);
    }

    List<Map<String, Object?>> clientFrames() => [
      for (final raw in server.clientControlFrames) (jsonDecode(raw) as Map).cast<String, Object?>(),
    ];

    test('a direct path that opens inside the head start is the only connection', () async {
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'lan');
      expect([for (final f in clientFrames()) f['type']].where((t) => t == 'connect.request'), hasLength(1));
      expect(host.handshakes, hasLength(1));
      expect(network.clients, hasLength(1));
      expect(network.clients.single.closed, isFalse);
      expect(server.controlRelayFrames, 0, reason: 'the Relay never attached');
    });

    test('a direct lane still stalled at the head start hands over to the Relay', () async {
      await account.close();
      // The ICE deadline alone would wait eight seconds; only the head start
      // can make the handover this fast.
      account = build(directHeadStart: const Duration(milliseconds: 200), directTimeout: const Duration(seconds: 8));
      network.outcome = FakeRtcOutcome.silent;
      final stopwatch = Stopwatch()..start();
      final client = await connect();
      stopwatch.stop();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'the head start, not the eight second ICE deadline, ended the direct stage',
      );
      expect(fallbacks, ['directTimeout'], reason: 'a stalled direct stage is a real direct-path failure');
      expect(
        client.remoteCarrier!.session!.networkDiagnostics!.fallbackReason,
        RemoteNetworkFallbackReason.directTimeout,
      );
      expect(host.handshakes, hasLength(1));
      await _eventually(() => network.clients.single.closed);
    });

    test('a Relay that carried the last session is reused without a direct attempt', () async {
      // A device without a peer connector is Relay-only; the memory becomes Relay.
      final connector = account.peerConnector;
      account.peerConnector = null;
      final first = await connect();
      expect(first.remoteCarrier!.state!.transport, 'relay');
      await first.close();
      account.peerConnector = connector;
      server.clientControlFrames.clear();

      final second = await connect();
      expect(await second.listSessions(), isEmpty);
      expect(second.remoteCarrier!.state!.transport, 'relay');
      final request = clientFrames().firstWhere((f) => f['type'] == 'connect.request');
      expect((request['payload']! as Map)['preferredTransports'], ['relay'], reason: 'no direct offer was made');
      expect(host.rtcOffers, isEmpty);
      expect(network.clients, isEmpty, reason: 'the remembered Relay never opens a direct candidate');
      await second.close();
    });

    test('one failed attempt forgets the remembered Relay and tries the direct path again', () async {
      final connector = account.peerConnector;
      account.peerConnector = null;
      final first = await connect();
      expect(first.remoteCarrier!.state!.transport, 'relay');
      await first.close();
      account.peerConnector = connector;

      // Fails after the Relay opened, so the failure disproves the memory.
      host.describeUnsupported = true;
      await expectLater(connect(), throwsA(isA<RemoteConnectException>()));
      host.describeUnsupported = false;

      final second = await connect();
      expect(await second.listSessions(), isEmpty);
      expect(second.remoteCarrier!.state!.transport, 'lan');
      expect(host.rtcOffers, hasLength(1), reason: 'the retry made its own direct offer');
      await second.close();
    });
  });
}

Future<void> _eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
