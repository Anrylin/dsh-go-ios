/// A short, redacted digest of an error's machine-readable details.
///
/// Two audiences, one rule: never repeat what the Host said verbatim. The Host
/// writes its messages for developers, so they name absolute paths, request
/// URLs, tokens and account addresses; a log line is fine with that, but a
/// banner the user can open is not. Everything here is therefore
/// *whitelisted* (only the keys a diagnosis actually needs) and *redacted*
/// (URLs, paths, tokens and e-mails are cut).
///
/// The output is a one-line `key=value; key=value` digest, bounded in both
/// value length and total length, so it stays greppable in a log and readable
/// in an expandable banner cell.
library;

/// Longest single value kept, in characters; longer ones are cut with `…`.
const int errorDigestValueLimit = 120;

/// Longest whole digest kept, in characters.
const int errorDigestLimit = 320;

/// Keys worth keeping: what failed, where, and how badly.
///
/// Deliberately no ids, no names, no free-form text. A key is only listed
/// here when its value is a small enum-like word (`reason`, `kind`, `status`)
/// or a number (`statusCode`, `attempt`).
const List<String> errorDigestKeys = <String>[
  'code',
  'reason',
  'kind',
  'phase',
  'status',
  'statusCode',
  'retryable',
  'field',
  'param',
  'method',
  'endpoint',
  'attempt',
  'limit',
  'scope',
  'size',
  'maxBytes',
  'transport',
  'provider',
];

/// `scheme://…` and bare `host/path` request URLs (no scheme needed).
final RegExp _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s,;)\]]+');
final RegExp _bareHost = RegExp(
  r'\b(?:[A-Za-z0-9\-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:/[^\s,;)\]]*)?',
);

/// POSIX and Windows absolute paths, plus bare long relative paths. Unicode
/// segments matter here: a Host may report `/Users/张三/私密/work`.
final RegExp _unixPath = RegExp(r'(?<![\w.])/(?:[^\s/\\]+/)+[^\s/\\]*');
final RegExp _cjkRelativePath = RegExp(r'(?<![\w.])[\u4e00-\u9fff][^\s/\\]*(?:[\\/][^\s/\\]+)+');
final RegExp _winPath = RegExp(r'\b[A-Za-z]:\\(?:[^\s\\]+\\)*[^\s\\]*');

/// Account addresses.
final RegExp _email = RegExp(r'\b[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+\b');

/// Secret-named assignments: `apiKey=abc12345`, `token: "ey…”`.
final RegExp _secretAssignment = RegExp(
  r'''\b([A-Za-z0-9_.-]*(?:api[_-]?key|apikey|access[_-]?key|private[_-]?key|token|secret|password)[A-Za-z0-9_.-]*)("?\s*[:=]\s*["']?)(?!<)[^\s"',;&]+''',
  caseSensitive: false,
);

/// Known credential prefixes, including short keys (`sk-…`, `ghp_…`, `AKIA…`)
/// that would slip past a pure length rule.
final RegExp _secretPrefix = RegExp(
  r'''\b(?:github_pat_[A-Za-z0-9_]{6,}|(?:sk|rk)[_-](?:live|test)[_-][A-Za-z0-9]{6,}|sk-[A-Za-z0-9]{6,}|(?:gh[pousr]_|xox[baprs]-|glpat-|whsec_|npm_|hf_)[A-Za-z0-9_\-]{6,}|(?:AIza|AKIA|ASIA|LTAI|AKID)[A-Za-z0-9_\-]{6,})''',
  caseSensitive: false,
);

/// Bearer-ish blobs: long runs of token characters (JWTs, hex, base64url).
final RegExp _token = RegExp(r'\b[A-Za-z0-9_\-]{24,}\b');

/// Removes secrets and locations from free-form diagnostic text.
///
/// A redaction leaves a marker (`<url>`, `<path>`, `<token>`, `<email>`) rather
/// than deleting the fragment, so the shape of the message survives.
String redactDiagnosticText(String text) => text
    .replaceAll(_url, '<url>')
    .replaceAll(_email, '<email>')
    .replaceAll(_bareHost, '<url>')
    .replaceAll(_winPath, '<path>')
    .replaceAll(_unixPath, '<path>')
    .replaceAll(_cjkRelativePath, '<path>')
    .replaceAllMapped(_secretAssignment, (m) => '${m[1]}${m[2]}<token>')
    .replaceAll(_secretPrefix, '<token>')
    .replaceAll(_token, '<token>');

/// A redacted, length-capped digest of [details]; empty when there is nothing
/// safe to show.
///
/// `null` and an empty map both return `''`, so callers can append the result
/// unconditionally.
String errorDigest(Map<String, Object?>? details, {int limit = errorDigestLimit}) {
  if (details == null || details.isEmpty) return '';
  final buffer = StringBuffer();
  for (final key in errorDigestKeys) {
    final value = _digestValue(details[key]);
    if (value == null) continue;
    final pair = '$key=$value';
    final next = buffer.isEmpty ? pair : '$buffer; $pair';
    if (next.length > limit) {
      if (buffer.isEmpty) {
        // A single oversized pair still deserves a truncated sighting.
        return '${pair.substring(0, limit)}…';
      }
      return '$buffer; …';
    }
    buffer.write(buffer.isEmpty ? pair : '; $pair');
  }
  return buffer.toString();
}

/// Scalars only; a nested map or an unknown object could carry anything.
String? _digestValue(Object? value) {
  final text = switch (value) {
    null => null,
    String() => value,
    num() => '$value',
    bool() => '$value',
    // A short list of scalars (allowed reasons, accepted presets) is useful.
    List() => _digestList(value),
    _ => null,
  };
  if (text == null) return null;
  final redacted = redactDiagnosticText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (redacted.isEmpty) return null;
  return redacted.length > errorDigestValueLimit
      ? '${redacted.substring(0, errorDigestValueLimit - 1)}…'
      : redacted;
}

String? _digestList(List<Object?> items) {
  final parts = <String>[];
  for (final item in items) {
    if (item is! String && item is! num && item is! bool) continue;
    parts.add('$item');
    if (parts.length == 4) break;
  }
  return parts.isEmpty ? null : parts.join('|');
}

/// `' · detail'` when there is a digest, `''` otherwise: the suffix
/// [DshRemoteException.toString] and its siblings append to their message.
String errorDigestSuffix(Map<String, Object?>? details) {
  final digest = errorDigest(details);
  return digest.isEmpty ? '' : ' [$digest]';
}