/// Projection of AGY transcript events into the existing DSH v3 History page
/// consumed by the native Chat UI.
library;

import '../util/bytes.dart';
import 'agy_catalog.dart';
import 'agy_values.dart';

const int _defaultHistoryMessages = 50;

JsonMap agyHistoryHeader(AgySession session) => <String, Object?>{
      'version': 3,
      'id': session.id,
      'createdAt': session.createdAt,
      'cwd': session.cwd,
      'isSeeded': false,
      if (session.selectedModel['model'] != null) 'model': session.selectedModel['model'],
      if (session.selectedModel['reasoningEffort'] != null) 'reasoningEffort': session.selectedModel['reasoningEffort'],
    };

List<JsonMap> agyNormalizeHistoryEvents(Object? rawEvents, AgySession session) {
  final entries = <JsonMap>[];
  var seq = 0;
  for (final raw in agyList(rawEvents)) {
    final value = agyMap(raw);
    final event = agyMap(value['event']);
    final type = agyString(event['type']) ?? agyString(value['type']);
    if (type == null) continue;
    final normalized = <String, Object?>{...event, 'type': type};
    normalized.putIfAbsent('seq', () => seq);
    normalized.putIfAbsent('time', () => agyNowMs());
    if (type == 'user/message' || type == 'assistant/message') {
      normalized.putIfAbsent('id', () => '$type:${normalized['seq']}');
      normalized.putIfAbsent('role', () => type == 'user/message' ? 'user' : 'assistant');
      final content = normalized['content'];
      if (content is! List<Object?>) {
        final text = agyString(normalized['text']) ?? '';
        normalized['content'] = text.isEmpty ? <Object?>[] : <Object?>[<String, Object?>{'type': 'text', 'text': text}];
      }
      normalized.putIfAbsent('stream', () => <Object?>[]);
      normalized.putIfAbsent('surfaceOp', () => 'append');
    }
    entries.add(<String, Object?>{'event': normalized});
    seq = (agyInt(normalized['seq']) ?? seq) + 1;
  }
  return entries;
}

/// Turns a raw `dsh/sessionHistory` response into a bounded v3 page.
JsonMap agyProjectHistory(Object? raw, AgySession session, [Map<String, Object?> request = const <String, Object?>{}]) {
  final source = agyMap(raw);
  final records = agyNormalizeHistoryEvents(source['records'] ?? source['events'], session);
  final lastSeq = agyInt(source['lastSeq']) ?? (records.isEmpty ? -1 : agyInt(records.last['event'] is Map<String, Object?>
          ? (records.last['event'] as Map<String, Object?>)['seq']
          : null) ?? records.length - 1);
  final throughSeq = agyInt(request['throughSeq']) ?? lastSeq;
  final beforeSeq = agyInt(request['beforeSeq']);
  final endSeq = beforeSeq == null ? throughSeq : (beforeSeq - 1 < throughSeq ? beforeSeq - 1 : throughSeq);
  final window = records.where((record) {
    final event = agyMap(record['event']);
    final seq = agyInt(event['seq']);
    return seq != null && seq <= endSeq;
  }).toList(growable: false);

  final maxMessages = agyInt(request['maxMessages']) ?? _defaultHistoryMessages;
  var messages = 0;
  var cut = 0;
  for (var index = window.length - 1; index >= 0; index -= 1) {
    final event = agyMap(window[index]['event']);
    final type = agyString(event['type']) ?? '';
    if ((type != 'user/message' && type != 'assistant/message') || event['surfaceOp'] != 'append') continue;
    messages += 1;
    if (messages >= maxMessages) {
      cut = agyInt(event['seq']) ?? 0;
      break;
    }
  }
  final visible = window.where((record) {
    final seq = agyInt(agyMap(record['event'])['seq']);
    return seq != null && seq >= cut;
  }).toList(growable: false);
  final header = <String, Object?>{...agyHistoryHeader(session), ...agyMap(source['header'])}
    ..['version'] = 3
    ..['id'] = session.id
    ..['isSeeded'] = false;
  return <String, Object?>{
    'header': header,
    'cursor': lastSeq,
    'records': visible,
    'hasMore': window.any((record) {
      final seq = agyInt(agyMap(record['event'])['seq']);
      return seq != null && seq < cut;
    }),
    if (session.running) 'activeTurnId': 'acp-live',
    'assistantStream': <String, Object?>{'revision': 0},
  };
}

/// Initial `session/follow` snapshot. Live frames follow this snapshot.
JsonMap agyHistorySnapshot(AgySession session, [JsonMap? page]) {
  final source = page ?? agyProjectHistory(const <String, Object?>{}, session);
  return <String, Object?>{
    'type': 'snapshot',
    'header': source['header'] ?? agyHistoryHeader(session),
    'cursor': source['cursor'] ?? -1,
    'records': source['records'] ?? const <Object?>[],
    'hasMore': source['hasMore'] ?? false,
    'projections': <String, Object?>{
      'kind': 'sequenced',
      'asOfSeq': source['cursor'] ?? -1,
      'values': agyProjections(session),
    },
    'assistantStream': source['assistantStream'] ?? <String, Object?>{'revision': 0},
    if (source['activeTurnId'] != null) 'activeTurnId': source['activeTurnId'],
  };
}

JsonMap agyProjections(AgySession session) => <String, Object?>{
      'title': session.title,
      'sessionListMetadata': <String, Object?>{
        'blank': session.updatedAt == 0,
        'lastPromptAt': session.updatedAt == 0 ? null : session.updatedAt,
      },
      'permissions': agyPermissionsProjection(session.permissionPreset),
      'imageLimits': <String, Object?>{
        'maxImageBytes': agyMaxImageBytes,
        'maxImagesPerMessage': agyMaxImages,
        'maxMessageImageBytes': agyMaxPromptImageBytes,
        'maxImagePixels': 40000000,
        'maxImageDimension': 8192,
        'mediaTypes': agyImageMimeTypes.toList()..sort(),
      },
      'modelSelection': agyModelSelectionProjection(session.selectedModel),
    };

JsonMap agyModelSelectionProjection(JsonMap selection) =>
    <String, Object?>{'lastUsed': selection, 'next': selection};

JsonMap agyPermissionsProjection(String? preset) => <String, Object?>{
      'options': <Object?>[
        <String, Object?>{
          'value': 'workspace-write',
          'name': 'workspace-write',
          'description': 'Interactive one-time approval for tool executions and commands.',
        },
        <String, Object?>{
          'value': 'danger-full-access',
          'name': 'danger-full-access',
          'description': 'Auto-approve tool requests for subsequent turns in this session.',
        },
      ],
      'currentValue': preset ?? 'Host settings (not reported)',
    };

/// A model row inside the projected catalog, mirroring the official
/// `parseAgyModels`: wire ids ending in an effort suffix become separate
/// variant rows, grouped by base model with their reasoning efforts ordered.
class AgyModelVariant {
  const AgyModelVariant(this.id, this.name, this.effort, this.wireId);

  final String id;
  final String name;
  final String? effort;
  final String wireId;
}

/// Splits a wire model id like `gemini-3-pro-high` into base id + effort.
/// Official `models.js` accepts exactly these six suffixes.
AgyModelVariant? agyParseModelVariant(String id) {
  for (final effort in const ['low', 'medium', 'high', 'xhigh', 'max', 'thinking']) {
    final suffix = '-$effort';
    if (id.length > suffix.length && id.toLowerCase().endsWith(suffix)) {
      final base = id.substring(0, id.length - suffix.length);
      final display = effort[0].toUpperCase() + effort.substring(1);
      return AgyModelVariant(base, display, effort, id);
    }
  }
  return null;
}

/// Strips a trailing `(Low|Medium|…|Thinking)` display-name suffix the way the
/// official parser does before regrouping variants under one base row.
String agyStripEffortName(String name) =>
    name.replaceFirst(RegExp(r'\s+\((Low|Medium|High|Xhigh|Max|Thinking)\)$', caseSensitive: false), '');

/// Projects a raw `dsh/sessionModels` response into the group-shaped catalog
/// the client's [ModelCatalog.fromJson] consumes, mirroring the official
/// `parseAgyModels`: wire model ids ending in an effort suffix collapse into
/// one base-model row whose `reasoning.efforts` carry `{id, name}` objects and
/// a `defaultEffort` (first effort seen for that base). [failures] keeps the
/// Host-reported provider failures verbatim.
JsonMap agyModelCatalogProjection(Object? raw) {
  final catalog = agyMap(raw);
  final groups = agyList(catalog['groups']).map(agyMap).toList();
  final projected = <JsonMap>[];
  for (final group in groups) {
    final models = <JsonMap>[];
    final baseOrder = <String>[];
    final baseNames = <String, String>{};
    final baseDescriptions = <String, String>{};
    final baseEfforts = <String, List<JsonMap>>{};
    final defaultEfforts = <String, String>{};
    final seenEfforts = <String, Set<String>>{};
    for (final value in agyList(group['models'])) {
      final model = agyMap(value);
      final wireId = agyString(model['id']) ?? agyString(model['wireId']) ?? agyString(model['model']);
      if (wireId == null) continue;
      final name = agyString(model['name']) ?? wireId;
      final variant = agyParseModelVariant(wireId);
      final baseId = variant?.id ?? wireId;
      final baseName = variant == null ? name : agyStripEffortName(name);
      final description = agyString(model['description']);
      if (!baseOrder.contains(baseId)) {
        baseOrder.add(baseId);
        baseNames[baseId] = baseName;
        if (description != null) baseDescriptions[baseId] = description;
        baseEfforts[baseId] = <JsonMap>[];
        seenEfforts[baseId] = <String>{};
      }
      if (variant != null) {
        if (seenEfforts[baseId]!.add(variant.effort!)) {
          baseEfforts[baseId]!.add(<String, Object?>{'id': variant.effort, 'name': variant.name});
          defaultEfforts.putIfAbsent(baseId, () => variant.effort!);
        }
      }
    }
    for (final baseId in baseOrder) {
      final efforts = baseEfforts[baseId]!;
      models.add(<String, Object?>{
        'id': baseId,
        'name': baseNames[baseId] ?? baseId,
        if (baseDescriptions[baseId] != null) 'description': baseDescriptions[baseId],
        'provider': agyString(group['id']) ?? agyBackend,
        if (efforts.isNotEmpty)
          'reasoning': <String, Object?>{
            'efforts': efforts,
            'defaultEffort': defaultEfforts[baseId],
          },
      });
    }
    projected.add(<String, Object?>{
      'id': agyString(group['id']) ?? agyBackend,
      'name': agyString(group['name']) ?? 'Antigravity',
      'models': models,
    });
  }
  return <String, Object?>{
    'default': agyMap(catalog['current']),
    'routableProviders': agyBool(catalog['routable'] ?? true) ? <Object?>[agyBackend] : const <Object?>[],
    'groups': projected,
    'failures': agyList(catalog['failures']),
  };
}

/// The static catalog handed out when no AGY session exists or discovery
/// failed: an empty Antigravity group with the Host-settings default, mirroring
/// the official `virtual-catalog.js` modelCatalog stub.
JsonMap agyEmptyModelCatalog() => <String, Object?>{
      'default': <String, Object?>{'provider': agyBackend, 'model': 'host-settings'},
      'routableProviders': const <Object?>[],
      'groups': <Object?>[
        <String, Object?>{'id': agyBackend, 'name': 'Antigravity', 'models': const <Object?>[]},
      ],
      'failures': const <Object?>[],
    };
