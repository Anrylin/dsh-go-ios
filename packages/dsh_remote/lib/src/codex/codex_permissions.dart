/// Codex permission preset projection from an `account/read` response, a
/// faithful Dart port of `dist/codex/permissions.js` (21 lines).
library;

import '../util/bytes.dart';
import 'codex_values.dart';

/// `sandbox` may be the string `workspace-write` / `danger-full-access` or an
/// object with `type: workspaceWrite` / `dangerFullAccess`; approval policy
/// must agree before a preset is reported. Returns `null` when the Host uses
/// settings this client cannot project (the composer then shows the literal
/// "Host settings (not reported)").
String? codexPermissionPresetFromResponse(Object? value) {
  final root = codexRecord(value);
  for (final settings in <JsonMap>[root, codexRecord(root['threadSettings'])]) {
    final sandbox = settings['sandbox'] ?? settings['sandboxPolicy'];
    final type = codexRecord(sandbox)['type'];
    if (settings['approvalPolicy'] == 'never' &&
        (sandbox == 'danger-full-access' || type == 'dangerFullAccess')) {
      return 'danger-full-access';
    }
    if (settings['approvalPolicy'] == 'on-request' &&
        (sandbox == 'workspace-write' || type == 'workspaceWrite')) {
      return 'workspace-write';
    }
  }
  return null;
}
