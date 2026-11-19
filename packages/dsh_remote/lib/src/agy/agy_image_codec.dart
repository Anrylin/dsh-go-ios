/// AGY image validation for `session/prompt`.
///
/// The ACP wire field is `mimeType` (Codex uses `mediaType`). The Host stores
/// the bytes and injects `<AGY_REMOTE_IMAGES>` into the CLI prompt; the client
/// only sends the canonical base64 payload.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../util/bytes.dart';
import 'agy_values.dart';

final RegExp _dataImageUrl = RegExp(r'^data:(image/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/]+={0,2})$');

String? agyImageMimeType(Object? value) {
  final mime = agyString(value);
  if (mime == null || !agyImageMimeTypes.contains(mime)) return null;
  return mime;
}

/// Returns ACP image blocks, or `null` when the content cannot be sent.
List<JsonMap>? agyValidatePromptImages(Object? content) {
  final parts = agyList(content);
  if (parts.isEmpty) return <JsonMap>[];
  final images = <JsonMap>[];
  var totalBytes = 0;
  for (final value in parts) {
    final part = agyMap(value);
    if (agyString(part['type']) != 'image') continue;
    if (images.length >= agyMaxImages) return null;
    final mime = agyImageMimeType(part['mimeType']);
    if (mime == null) return null;
    final rawData = agyString(part['data']);
    if (rawData == null || rawData.isEmpty) return null;
    final match = _dataImageUrl.firstMatch(rawData);
    final data = match != null
        ? match.group(2)!
        : (rawData.startsWith('data:') ? null : rawData);
    if (data == null || data.length > ((agyMaxImageBytes + 2) ~/ 3) * 4) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty || bytes.length > agyMaxImageBytes || base64Encode(bytes) != data) return null;
    totalBytes += bytes.length;
    if (totalBytes > agyMaxPromptImageBytes) return null;
    images.add(<String, Object?>{
      'type': 'image',
      'mimeType': mime,
      'data': data,
    });
  }
  return images;
}

String agyImageExtension(String mimeType) => switch (mimeType) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'png',
    };
