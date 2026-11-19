/// Small ACP virtual-contract helpers, mirroring `dist/acp/virtual-contract.js`
/// and the payload unwrapping used by `CodexVirtualCarrier`.
library;

import 'package:dsh_client/dsh_client.dart';

import '../channel/rpc_client.dart';
import '../util/bytes.dart';
import 'agy_values.dart';

RpcResult agySuccess(Object? value) => RpcOk(value);

RpcResult agyFailure(String code, String message, [JsonMap details = const <String, Object?>{}]) =>
    RpcError(DshRemoteException(code, message, details));

RpcResult agyFailFrom(Object? error) {
  final code = agyErrorCode(error) ?? 'internal';
  final message = agyErrorMessage(error);
  JsonMap details = const <String, Object?>{};
  if (error is DshRemoteException) {
    details = agyMap(error.details);
  } else if (error is RemoteRpcException) {
    details = agyMap(error.details);
  }
  return agyFailure(code, message, details);
}

/// Unwraps the Host's `{ok:true,value}` / `{ok:false,error}` envelopes; a
/// plain value is returned unchanged.
Object? agyBusiness(Object? value) {
  final result = asMap(value);
  if (result == null) return value;
  if (result['ok'] == true) return result['value'];
  if (result['ok'] == false) {
    final error = agyMap(result['error']);
    throw AgyFailure(
      agyString(error['code']) ?? 'internal',
      agyString(error['message']) ?? 'The ACP Host rejected the request.',
    );
  }
  return value;
}

/// The Host carrier wraps every virtual endpoint payload in `{"args":…}`.
JsonMap agyCarrierArgs(Object? payload) => agyMap(agyMap(payload)['args']);

JsonMap agyRequestArg(JsonMap args) => agyMap(args['request'] ?? args['_request'] ?? args);

String agyRequiredString(Object? value, String field) {
  final text = agyString(value);
  if (text == null || text.isEmpty) {
    throw AgyFailure('invalid-arguments', '$field is required.');
  }
  return text;
}

String agyExtractSessionId(JsonMap request) {
  final direct = agyString(request['sessionId']) ?? agyString(request['sessionID']);
  if (direct != null && direct.isNotEmpty) return agyVirtualId(direct);
  final address = agyMap(request['address']);
  if (address['kind'] == 'session') {
    return agyVirtualId(agyRequiredString(address['sessionId'], 'sessionId'));
  }
  return agyVirtualId(agyRequiredString(address['childSessionId'], 'childSessionId'));
}

String agyExtractPromptText(Object? content) {
  final parts = agyList(content);
  if (parts.isEmpty) return agyString(content) ?? '';
  final buffer = StringBuffer();
  for (final part in parts) {
    final map = agyMap(part);
    if (agyString(map['type']) != 'text') continue;
    final text = agyString(map['text']);
    if (text != null) buffer.write(text);
  }
  return buffer.toString();
}

String? agyExtractText(Object? value) {
  if (value is String) return value;
  final map = agyMap(value);
  final text = agyString(map['text']);
  if (text != null) return text;
  return agyExtractPromptText(map['content']);
}

bool agyIsSurfaceEvent(String type) =>
    type == 'user/message' ||
    type == 'assistant/message' ||
    type == 'assistant/thinking' ||
    type == 'tool/call' ||
    type == 'tool/call_update' ||
    type == 'turn/start' ||
    type == 'turn/end' ||
    type == 'step/start' ||
    type == 'step/end' ||
    type == 'model/selection' ||
    type == 'permission/selection' ||
    type == 'session/title' ||
    type == 'session/error';

bool agyIsPermissionPreset(Object? value) => value == 'workspace-write' || value == 'danger-full-access';

int? agyPositiveInt(Object? value) {
  final number = agyInt(value);
  return number != null && number > 0 ? number : null;
}

JsonMap agySessionSummary(JsonMap session) => <String, Object?>{
      'id': agyString(session['id']) ?? '',
      'sessionId': agyString(session['id']) ?? '',
      'title': agyString(session['title']) ?? 'Untitled Session',
      'cwd': agyString(session['cwd']) ?? '',
      'createdAt': agyInt(session['createdAt']) ?? 0,
      'updatedAt': agyInt(session['updatedAt']) ?? 0,
      'running': agyBool(session['running']),
      if (session['blank'] != null) 'blank': agyBool(session['blank']),
    };
