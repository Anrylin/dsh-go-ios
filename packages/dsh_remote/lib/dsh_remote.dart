/// Pure-Dart client for ds-harness-remote (https://github.com/liguobao/ds-harness-remote,
/// MIT): reach a remote Host's DSH Harness API through the Server Relay, or
/// directly over WebRTC, with end-to-end Noise IK encryption, using the same
/// `DshClient` API as the local engine.
///
/// Entry point: [RemoteAccount] (sign-in, Host list, [RemoteAccount.connectHost]).
///
/// Layers, lowest first:
/// * [RemoteServerApi] — REST (`/api/v1/*`): providers, QR / password
///   login, device registration, token refresh, Host directory.
/// * [RelayTransport] — Control WebSocket: hello, connect, relay frames,
///   ping/pong, WebRTC signaling.
/// * [WebRtcTransport] — LAN / P2P / TURN: Noise ciphertext over a
///   DataChannel of a platform [RemotePeerConnection] (flutter_webrtc in the
///   app), falling back to the Relay.
/// * [NoiseIkSession] + [SecureChannel] — `Noise_IK_25519_ChaChaPoly_SHA256`,
///   DSHF fragmentation, replay protection.
/// * [RemoteRpcClient] — Remote message RPC correlation and events.
/// * [RemoteTunnelCarrier] — `DshCarrier` mapping `DshRpc` / `DshMux` onto
///   `harness.remote.call` / `harness.remote.stream.*`.
library;

export 'package:dsh_client/dsh_client.dart';

export 'src/account/remote_account.dart'
    show HostTrustPrompt, RemoteAccount, RemoteHost, RemoteHostTrust, RemoteLogin, RemoteUser;
export 'src/agent/remote_agent.dart';
export 'src/account/secret_store.dart';
export 'src/agy/agy_api.dart';
export 'src/agy/agy_catalog.dart';
export 'src/agy/agy_contract.dart';
export 'src/agy/agy_events.dart';
export 'src/agy/agy_history.dart';
export 'src/agy/agy_image_codec.dart';
export 'src/agy/agy_live.dart';
export 'src/agy/agy_values.dart' hide directRemoteCallBytes, maxSecureMessageBytes;
export 'src/agy/agy_virtual.dart';
export 'src/carrier/tunnel_carrier.dart';
export 'src/channel/rpc_client.dart';
export 'src/channel/secure_channel.dart';
export 'src/codex/codex_api.dart';
export 'src/codex/codex_catalog.dart';
export 'src/codex/codex_contract.dart';
export 'src/codex/codex_events.dart';
export 'src/codex/codex_history.dart';
export 'src/codex/codex_history_cache.dart';
export 'src/codex/codex_image_codec.dart';
export 'src/codex/codex_live.dart';
export 'src/codex/codex_permissions.dart';
export 'src/codex/codex_turn_end.dart';
export 'src/codex/codex_values.dart';
export 'src/codex/codex_virtual.dart';
export 'src/crypto/noise_ik.dart'
    show
        NoiseIkSession,
        NoiseRole,
        NoiseSessionError,
        X25519KeyPair,
        createNoisePrologue,
        formatFingerprint,
        identityFingerprint,
        noiseIkProtocol;
export 'src/protocol/control.dart' show ControlFrame, ControlFrameLimits, ProtocolError, protocolVersion;
export 'src/protocol/messages.dart' show RemoteMessage, SecureMessageCodec, maxSecureMessageBytes;
export 'src/server/server_api.dart';
export 'src/state.dart';
export 'src/transport/peer_connection.dart';
export 'src/transport/relay_transport.dart';
export 'src/transport/transport.dart';
export 'src/transport/webrtc_transport.dart';
