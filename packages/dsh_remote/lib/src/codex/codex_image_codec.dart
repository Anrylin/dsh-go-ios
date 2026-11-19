/// Image block extraction and inline image projection for Codex turns, a
/// faithful Dart port of the official Web client's `codex-image-codec.js`
/// (`ds-harness-remote` v0.6.4, `dist/codex/codex-image-codec.js`, 288 lines).
///
/// The Host stores images as canonical base64 `data:` URLs or `image` content
/// blocks; DSH chat renders them through inline attachments whose ids include
/// a stable FNV-1a hash of `attachmentSeed:index`.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../util/bytes.dart';
import 'codex_values.dart';

const Set<String> codexImageMediaTypes = <String>{'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
const String codexImageAttachmentPrefix = 'codex-image:';
const int maxCodexImageBase64 = 288 * 1024 * 1024;

final RegExp _dataImageUrl = RegExp(r'^data:(image/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/]+={0,2})$');
final RegExp _canonicalBase64 =
    RegExp(r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$');

class _CodexImage {
  const _CodexImage(this.mediaType, this.data, this.url);

  final String mediaType;
  final String data;
  final String url;
}

/// Canonical standard base64; Dart is stricter than JS `atob`, so the regex
/// is authoritative (no whitespace, no url-safe alphabet, correct padding).
bool codexIsCanonicalBase64(String value) =>
    value.length >= 4 && value.length % 4 == 0 && _canonicalBase64.hasMatch(value);

/// Picks the first candidate carrying a usable image block, mirroring the
/// official candidate order: tool result content, tool output content,
/// `contentItems`, then an array-shaped `output`.
List<JsonMap> codexToolOutputImageBlocks(Object? item) {
  final record = codexRecord(item);
  final candidates = <Object?>[
    codexRecord(record['result'])['content'],
    codexRecord(record['output'])['content'],
    record['contentItems'],
    if (record['output'] is List) record['output'],
  ];
  for (final candidate in candidates) {
    final list = codexArray(candidate);
    if (list.isEmpty) continue;
    final images = <JsonMap>[];
    for (final value in list) {
      final block = codexRecord(value);
      if (_isImageContent(block) && _parseImageBlock(block) != null) images.add(block);
    }
    if (images.isNotEmpty) return images;
  }
  return const <JsonMap>[];
}

/// Converts a turn item's `content` (string or array of parts) into DSH chat
/// content blocks. Images become `{type: image, attachment: {...}}` with a
/// stable id; unsupported parts are dropped, text/reasoning preserved.
List<JsonMap> codexContentBlocks(Object? value, String attachmentSeed) {
  if (value is String) return <JsonMap>[<String, Object?>{'type': 'text', 'text': value}];
  final list = codexArray(value);
  if (list.isEmpty && value is! List) return const <JsonMap>[];
  final blocks = <JsonMap>[];
  var imageIndex = 0;
  for (final raw in list) {
    if (raw is String) {
      blocks.add(<String, Object?>{'type': 'text', 'text': raw});
      continue;
    }
    final block = codexRecord(raw);
    final image = _imageContentBlock(block, attachmentSeed, imageIndex);
    if (image != null) {
      imageIndex += 1;
      blocks.add(image);
      continue;
    }
    final text = codexString(block['text']) ?? codexString(block['content']);
    if (text != null) {
      blocks.add(<String, Object?>{
        'type': block['type'] == 'reasoning' ? 'reasoning' : 'text',
        'text': text,
      });
    }
  }
  return blocks;
}

/// Recursively collects all `image` blocks under the keys the Host uses for
/// nested turn content. The `attachment` key is skipped to avoid duplicates.
List<Object?> codexCollectImageBlocks(Object? value, [List<Object?>? output]) {
  final result = output ?? <Object?>[];
  if (value is List) {
    for (final item in value) {
      codexCollectImageBlocks(item, result);
    }
    return result;
  }
  final record = codexRecord(value);
  if (record.isEmpty && value is! Map) return result;
  if (record['type'] == 'image') result.add(value);
  for (final key in const <String>['content', 'message', 'inserted', 'chunk', 'block']) {
    final child = record[key];
    if (child != null) codexCollectImageBlocks(child, result);
  }
  return result;
}

bool _isImageContent(JsonMap block) => block['type'] == 'image' || block['type'] == 'input_image';

JsonMap? _imageContentBlock(JsonMap block, String attachmentSeed, int index) {
  if (!_isImageContent(block)) return null;
  final image = _parseImageBlock(block);
  if (image == null) return null;
  final dimensions = _imageDimensions(image.mediaType, image.data);
  final name = codexString(block['name']);
  final attachment = <String, Object?>{
    'attachmentId': '$codexImageAttachmentPrefix${_imageHash('$attachmentSeed:$index')}:$index',
    'mediaType': image.mediaType,
    'bytes': _base64ByteLength(image.data),
    'width': dimensions.width,
    'height': dimensions.height,
    if (name != null) 'name': name,
  };
  return <String, Object?>{
    'type': 'image',
    'attachment': attachment,
    'mediaType': image.mediaType,
    'data': image.data,
    'url': image.url,
    if (name != null) 'name': name,
  };
}

_CodexImage? _parseImageBlock(JsonMap block) {
  final url = codexString(block['url']) ??
      codexString(block['image_url']) ??
      codexString(codexRecord(block['image_url'])['url']);
  final parsed = url == null ? null : _parseDataImageUrl(url);
  if (parsed != null) return parsed;
  final data = codexString(block['data']);
  if (data == null || !codexIsCanonicalBase64(data)) return null;
  if (data.length > maxCodexImageBase64) return null;
  final mediaType = codexString(block['mediaType']) ??
      codexString(block['mimeType']) ??
      _sniffImageMediaType(data);
  if (mediaType == null || !codexImageMediaTypes.contains(mediaType)) return null;
  return _CodexImage(mediaType, data, 'data:$mediaType;base64,$data');
}

_CodexImage? _parseDataImageUrl(String value) {
  final match = _dataImageUrl.firstMatch(value);
  if (match == null) return null;
  final mediaType = match.group(1)!;
  final data = match.group(2)!;
  if (!codexImageMediaTypes.contains(mediaType) || !codexIsCanonicalBase64(data)) return null;
  return _CodexImage(mediaType, data, 'data:$mediaType;base64,$data');
}

int _base64ByteLength(String value) {
  final padding = value.endsWith('==') ? 2 : (value.endsWith('=') ? 1 : 0);
  final length = (value.length * 3) ~/ 4 - padding;
  return length > 1 ? length : 1;
}

({int width, int height}) _imageDimensions(String mediaType, String data) {
  final bytes = _base64PrefixBytes(data, 256 * 1024);
  final parsed = switch (mediaType) {
    'image/png' => _pngDimensions(bytes),
    'image/jpeg' => _jpegDimensions(bytes),
    'image/gif' => _gifDimensions(bytes),
    'image/webp' => _webpDimensions(bytes),
    _ => null,
  };
  return parsed ?? (width: 1, height: 1);
}

({int width, int height})? _pngDimensions(Uint8List bytes) {
  const signature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  return _positiveDimensions(_readUint32BE(bytes, 16), _readUint32BE(bytes, 20));
}

({int width, int height})? _jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  var offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] != 0xff) {
      offset += 1;
      continue;
    }
    final marker = bytes[offset + 1];
    offset += 2;
    if (marker == 0xd8 || marker == 0xd9) continue;
    if (offset + 2 > bytes.length) return null;
    final length = _readUint16BE(bytes, offset);
    if (length < 2 || offset + length > bytes.length) return null;
    if (_isJpegSof(marker) && length >= 7) {
      return _positiveDimensions(_readUint16BE(bytes, offset + 5), _readUint16BE(bytes, offset + 3));
    }
    offset += length;
  }
  return null;
}

({int width, int height})? _gifDimensions(Uint8List bytes) {
  if (bytes.length < 10 ||
      bytes[0] != 0x47 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x38 ||
      (bytes[4] != 0x37 && bytes[4] != 0x39) ||
      bytes[5] != 0x61) {
    return null;
  }
  return _positiveDimensions(_readUint16LE(bytes, 6), _readUint16LE(bytes, 8));
}

({int width, int height})? _webpDimensions(Uint8List bytes) {
  if (bytes.length < 30 ||
      _stringFromBytes(bytes, 0, 4) != 'RIFF' ||
      _stringFromBytes(bytes, 8, 12) != 'WEBP') {
    return null;
  }
  final chunk = _stringFromBytes(bytes, 12, 16);
  if (chunk == 'VP8X') {
    return _positiveDimensions(1 + _readUint24LE(bytes, 24), 1 + _readUint24LE(bytes, 27));
  }
  if (chunk == 'VP8L' && bytes[20] == 0x2f) {
    final b0 = bytes[21];
    final b1 = bytes[22];
    final b2 = bytes[23];
    final b3 = bytes[24];
    final width = 1 + b0 + ((b1 & 0x3f) << 8);
    final height = 1 + ((b1 & 0xc0) >> 6) + (b2 << 2) + ((b3 & 0x0f) << 10);
    return _positiveDimensions(width, height);
  }
  if (chunk == 'VP8 ' && bytes[23] == 0x9d && bytes[24] == 0x01 && bytes[25] == 0x2a) {
    return _positiveDimensions(
      _readUint16LE(bytes, 26) & 0x3fff,
      _readUint16LE(bytes, 28) & 0x3fff,
    );
  }
  return null;
}

String? _sniffImageMediaType(String data) {
  final bytes = _base64PrefixBytes(data, 32);
  if (_pngDimensions(bytes) != null) return 'image/png';
  if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return 'image/jpeg';
  if (_gifDimensions(bytes) != null) return 'image/gif';
  if (bytes.length >= 12 && _stringFromBytes(bytes, 0, 4) == 'RIFF' && _stringFromBytes(bytes, 8, 12) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

Uint8List _base64PrefixBytes(String value, int maxBytes) {
  final wanted = ((maxBytes + 2) ~/ 3) * 4;
  final end = wanted < value.length ? wanted : value.length;
  final slice = value.substring(0, end);
  try {
    final decoded = base64.decode(slice);
    return Uint8List.fromList(decoded.take(maxBytes).toList());
  } on FormatException {
    return Uint8List(0);
  }
}

int _readUint16BE(Uint8List bytes, int offset) => (bytes[offset] << 8) + bytes[offset + 1];

int _readUint16LE(Uint8List bytes, int offset) => bytes[offset] + (bytes[offset + 1] << 8);

int _readUint24LE(Uint8List bytes, int offset) =>
    bytes[offset] + (bytes[offset + 1] << 8) + (bytes[offset + 2] << 16);

int _readUint32BE(Uint8List bytes, int offset) =>
    (bytes[offset] * 0x1000000) +
    (bytes[offset + 1] * 0x10000) +
    (bytes[offset + 2] * 0x100) +
    bytes[offset + 3];

({int width, int height})? _positiveDimensions(int width, int height) =>
    width > 0 && height > 0 ? (width: width, height: height) : null;

bool _isJpegSof(int marker) =>
    (marker >= 0xc0 && marker <= 0xc3) ||
    (marker >= 0xc5 && marker <= 0xc7) ||
    (marker >= 0xc9 && marker <= 0xcb) ||
    (marker >= 0xcd && marker <= 0xcf);

String _stringFromBytes(Uint8List bytes, int start, int end) {
  if (bytes.length < end) return '';
  final buffer = StringBuffer();
  for (var i = start; i < end; i++) {
    buffer.writeCharCode(bytes[i]);
  }
  return buffer.toString();
}

/// FNV-1a over UTF-16 code units rendered as fixed-width lowercase hex 8.
/// Different from [codexHashString] (base36) on purpose: this is the official
/// inline attachment id hash.
String _imageHash(String value) {
  int hash = 2166136261;
  for (final unit in value.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 16777619) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
