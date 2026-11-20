// The diagnostics bundle, one ZIP a user can attach to a
// bug report. Gathered into a [DiagnosticsSnapshot] first, so the archive
// itself is built by pure functions (and tested as such).
//
//   dsh-go-diagnostics-20261024-153012.zip
//   ├── summary.json   app and DSH versions, device, Android, runtime manifest,
//   │                  engine state, connection kind
//   ├── settings.json  app settings, secrets reduced to "set or not"
//   ├── app-events.json structured app event ring (always present, `[]` if empty)
//   ├── crash.json     the last crash classification (when there is one)
//   ├── engine.log     recent engine output
//   └── failure.log    output around the last failure (when there is one)
//
// Every string goes through `redactDiagnostics` on the way in. App events are
// redacted again when written, so an older event cannot bypass a newer mask.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../performance/performance_state.dart';
import '../runtime/runtime_state.dart';
import '../state/app_info.dart';
import '../state/connection_state.dart';
import '../state/settings_state.dart';
import '../state/voice_settings.dart';
import 'app_error_log.dart';
import 'app_event_log.dart';
import 'diagnostics_channel.dart';
import 'redact.dart';
import 'zip_writer.dart';

/// Most engine log lines a bundle carries (the native in-memory log's size).
const diagnosticsLogLines = 2000;

/// Everything a bundle is made of, read from the app and Android.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.at,
    required this.status,
    required this.settings,
    this.native = const NativeDiagnostics(),
    this.connection = const {},
    this.performance = const {},
    this.voiceMode = VoiceMode.auto,
    this.engineLog = const [],
    this.failureLog = const [],
    this.appErrors = const [],
    this.appEvents = const [],
    this.droppedEvents = 0,
    this.appEventCapacity = defaultAppEventCapacity,
  });

  final DateTime at;
  final RuntimeStatus status;
  final AppSettings settings;
  final NativeDiagnostics native;

  /// Last observed connection state and remote link stage; may be stale.
  /// `not_observed` means no active observation is currently retained.
  final Map<String, Object?> connection;
  final Map<String, Object?> performance;
  final VoiceMode voiceMode;
  final List<String> engineLog;
  final List<String> failureLog;
  final List<AppErrorRecord> appErrors;
  final List<AppEventRecord> appEvents;
  final int droppedEvents;
  final int appEventCapacity;
}

abstract final class DiagnosticsBundle {
  static const mime = 'application/zip';

  /// `dsh-go-diagnostics-20261024-153012.zip` (ASCII: it travels through
  /// share targets and mail clients).
  static String fileName(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'dsh-go-diagnostics-${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}.zip';
  }

  /// Identity columns added to every summary's `connection`. Values are
  /// supplied by [collectDiagnostics] when the app actually observed them;
  /// absent ones stay null so the schema is stable across builds.
  static const connectionIdentityKeys = <String>[
    'hostId',
    'hostKind',
    'agent',
    'clientId',
    'sessionId',
    'turnId',
    'requestId',
    'muxGeneration',
    'followEpoch',
    'connectedAt',
  ];

  static Map<String, Object?> connectionSummary(Map<String, Object?> observed) {
    final out = <String, Object?>{...observed};
    for (final key in connectionIdentityKeys) {
      out.putIfAbsent(key, () => null);
    }
    return out;
  }

  static Map<String, Object?> summary(DiagnosticsSnapshot s) {
    final status = s.status;
    return {
      'generatedAt': s.at.toUtc().toIso8601String(),
      'timeZoneOffsetMinutes': s.at.timeZoneOffset.inMinutes,
      'app': {'version': AppInfo.version, ...s.native.app},
      'device': s.native.device,
      'runtime': {
        'phase': status.phase.name,
        ...status.launchDiagnostics,
        'mode': status.mode.name,
        'safeState': status.safeState.name,
        'safeReason': status.safeReason,
        'strikes': status.strikes,
        'autoSafe': status.autoSafe,
        'abi': status.abi,
        'bundledVersion': status.bundledVersion,
        'installedVersion': status.installedVersion,
        'dshVersion': status.dshVersion,
        'nodeVersion': status.nodeVersion,
        'baseUrl': status.baseUrl,
        'error': status.error,
      },
      'manifest': s.native.manifest,
      'connection': connectionSummary(s.connection),
      'performance': s.performance,
      'appEvents': {'count': s.appEvents.length, 'droppedEvents': s.droppedEvents, 'capacity': s.appEventCapacity},
      'voice': {...voiceDiagnosticsFacts(s.native.voice), 'mode': s.voiceMode.name},
    };
  }

  /// The app's settings; the API key only as whether one is set.
  static Map<String, Object?> settingsSummary(AppSettings s) => {
    'hasApiKey': s.hasApiKey,
    'customProviders': s.customProviderIds.length,
    'themeMode': s.themeMode.name,
    'chatTextScale': s.chatTextScale,
    'autoStartLocal': s.autoStartLocal,
    'autoStartLocalExplicit': s.autoStartLocalExplicit,
    'autoApproveCommands': s.autoApproveCommands,
    'phoneStorage': s.phoneStorage,
    'webPhoneLayout': s.webPhoneLayout,
    'foldCompletedTurns': s.foldCompletedTurns,
    'visualReplies': s.visualReplies,
  };

  /// The native crash classification: the last unexpected exit and, when it
  /// is a different one, the main profile's last failure. Null without
  /// either.
  static Map<String, Object?>? crash(RuntimeStatus status) {
    final latest = status.failure;
    final main = status.mainFailure;
    if (latest == null && main == null) return null;
    final sameAsLatest = latest != null && main != null && main.at == latest.at && main.kind == latest.kind;
    return {
      if (latest != null) 'latest': _failure(latest),
      if (main != null && !sameAsLatest) 'mainProfile': _failure(main),
    };
  }

  static Map<String, Object?> _failure(RuntimeFailure f) => {
    'kind': f.kind.name,
    'at': f.at.toUtc().toIso8601String(),
    'exitCode': f.exitCode,
    'safeMode': f.safeMode,
    'upSeconds': f.upSeconds,
    'summary': f.summary,
    'requiredRows': f.requiredRows,
    'suspects': f.suspects,
    'recent': f.recent,
    'diagnostics': f.diagnostics,
  };

  /// The archive's files, every string redacted.
  static List<ZipEntry> entries(DiagnosticsSnapshot s) {
    const json = JsonEncoder.withIndent('  ');
    ZipEntry text(String name, String body) => ZipEntry(name, utf8.encode(body));
    ZipEntry jsonFile(String name, Object? value, {int lineLimit = maxLineLength}) =>
        text(name, '${json.convert(redactJson(value, lineLimit: lineLimit))}\n');
    String log(List<String> lines) {
      final tail = lines.length > diagnosticsLogLines ? lines.sublist(lines.length - diagnosticsLogLines) : lines;
      return '${redactLines(tail).join('\n')}\n';
    }

    final crash = DiagnosticsBundle.crash(s.status);
    return [
      jsonFile('summary.json', summary(s)),
      jsonFile('settings.json', settingsSummary(s.settings)),
      // Unconditional: an empty ring is itself a diagnostic fact. Events
      // already carry an explicit truncation marker; do not re-truncate here.
      jsonFile('app-events.json', [
        for (final event in s.appEvents) event.toJson(),
      ], lineLimit: appEventRedactionLineLimit),
      if (crash != null) jsonFile('crash.json', crash),
      if (s.engineLog.isNotEmpty) text('engine.log', log(s.engineLog)),
      if (s.failureLog.isNotEmpty) text('failure.log', log(s.failureLog)),
      if (s.appErrors.isNotEmpty) jsonFile('app-errors.json', s.appErrors.map((error) => error.toJson()).toList()),
    ];
  }

  static Uint8List build(DiagnosticsSnapshot s) => buildZip(entries(s), modified: s.at);
}

/// Reads a [DiagnosticsSnapshot] from the app's state and native side. Every
/// source is optional: a part that can't be read is left out, and the fallback
/// is recorded as an app event instead of being silently swallowed.
Future<DiagnosticsSnapshot> collectDiagnostics(Ref ref, DateTime at) async {
  final runtime = ref.read(localRuntimeProvider);
  final logs = ref.read(localRuntimeLogsProvider);
  final settings = ref.read(settingsProvider);
  final bridge = ref.read(runtimeBridgeProvider);
  final channel = ref.read(diagnosticsChannelProvider);

  final native = await diagnosticsAttempt('native.info', 'empty native', channel.info, const NativeDiagnostics());
  // The log file outlives the app process; the in-memory log is the
  // fallback (and what tests see).
  var engineLog = await diagnosticsAttempt('native.engineLog', 'empty log', channel.engineLog, const <String>[]);
  if (engineLog.isEmpty) {
    engineLog = await diagnosticsAttempt(
      'bridge.logs',
      'in-memory engine log',
      () => bridge.logs(lines: diagnosticsLogLines),
      logs,
    );
  }
  if (engineLog.isEmpty) engineLog = logs;
  final status = runtime.status;
  final failureLog = status.failure != null || status.mainFailure != null
      ? await diagnosticsAttempt('bridge.failureLog', 'empty log', bridge.failureLog, const <String>[])
      : const <String>[];

  return DiagnosticsSnapshot(
    at: at,
    status: status,
    settings: settings,
    native: native,
    connection: _connectionIdentity(ref, ref.read(connectionDiagnosticsProvider).snapshot),
    performance: performanceDiagnostics(ref),
    voiceMode: await diagnosticsAttempt(
      'voice.ready',
      'auto',
      () => ref.read(voiceSettingsProvider.notifier).ready(),
      VoiceMode.auto,
    ),
    engineLog: engineLog,
    failureLog: failureLog,
    appErrors: appErrorLog.snapshot(),
    appEvents: appEventLog.snapshot(),
    droppedEvents: appEventLog.droppedEvents,
    appEventCapacity: appEventLog.capacity,
  );
}

/// Enriches the already-observed connection with identity fields the app can
/// actually prove. Nothing is invented: unknown columns stay null and are
/// filled in as null by [DiagnosticsBundle.connectionSummary].
Map<String, Object?> _connectionIdentity(Ref ref, Map<String, Object?> observed) {
  final result = <String, Object?>{...observed};
  final host = observed['host'];
  if (host is String && host.isNotEmpty && host != 'not_observed') result['hostKind'] = host;

  HostConnection? active;
  try {
    // Reading an unbuilt connection would create one (and start native work).
    if (ref.exists(activeConnectionProvider)) {
      active = ref.read(activeConnectionProvider).value;
    }
  } catch (_) {
    // Diagnostics must never build or break a connection of its own.
    active = null;
  }
  if (active != null) {
    result['hostKind'] ??= active.kind.name;
    final hostId = active.hostId;
    if (hostId != null && hostId.isNotEmpty) result['hostId'] = maskDiagnosticsId(hostId);
    result['agent'] = active.agent.code;
    final generation = active.client.mux.generation;
    if (generation != null) {
      result['clientId'] = maskDiagnosticsId(generation.clientId);
      result['muxGeneration'] = generation.number;
    }
  }
  return result;
}

/// One optional source read. A failure becomes an event carrying the source,
/// exception type, redacted message and the fallback that was used. Public so
/// the behavior is testable without a live channel or bridge.
Future<T> diagnosticsAttempt<T>(
  String source,
  String fallbackName,
  Future<T> Function() read,
  T fallback, {
  Duration timeout = const Duration(seconds: 5),
  AppEventLog? log,
}) async {
  try {
    return await read().timeout(timeout);
  } catch (error) {
    (log ?? appEventLog).record(
      topic: 'diagnostics_collect',
      event: 'source_fallback',
      fields: {
        'source': source,
        'errorType': error.runtimeType.toString(),
        'errorMessage': error.toString(),
        'fallback': fallbackName,
      },
    );
    return fallback;
  }
}
