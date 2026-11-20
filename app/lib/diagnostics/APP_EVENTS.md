# App event log (diagnostics埋点 API)

Stable entry points (all in `app/lib/diagnostics/`):

- `appEventLog` — the process-wide `AppEventLog` singleton. Call `record` directly.
- `appEventLogProvider` — the same instance for widgets (`ref.read(appEventLogProvider)`).
- `AppEventLog(...)` — an isolated instance for tests or subsystems that want their own ring.

```dart
import 'package:dsh_app/diagnostics/app_event_log.dart';

appEventLog.record(
  topic: 'agent_switch',
  event: 'connected',
  fields: {
    'hostKind': host.kind.name,
    'hostId': host.id,
    'agent': agent.code,
    'clientId': generation.clientId,
    'sessionId': sessionId,
    'turnId': turnId,
    'requestId': requestId,
    'muxGeneration': generation.number,
    'followEpoch': epoch.toString(),
    'toolName': toolName,
    'durationMs': elapsed.inMilliseconds,
    'payload': {'workspace': workspace},
  },
);
```

`topic`/`event` are short stable names (snake_case). `fields` is open: known
columns below are promoted into the schema, unknown keys are preserved as-is.

| field | meaning |
| --- | --- |
| `at` | assigned by the ring (UTC ISO-8601 in JSON) |
| `seq` | assigned by the ring, monotonic for the process |
| `topic`, `event` | what happened |
| `hostKind`, `hostId`, `agent`, `clientId` | which connection / Agent |
| `sessionId`, `turnId`, `requestId` | which conversation / turn / request |
| `muxGeneration`, `followEpoch` | generation / follow-epoch identity |
| `toolName` | tool or connector name, when relevant |
| `errorCode`, `errorType`, `errorMessage` | failure details (already redacted) |
| `source`, `fallback` | where a swallowed failure came from and what replaced it |
| `durationMs` | elapsed time |
| `payload` | extra structured data (map or string), length bounded |
| `payloadTruncated` | true when the payload exceeded the cap |

## Redaction (automatic, do not pre-mask)

- Every string goes through the existing `redactDiagnostics`.
- Keys matching `secret` / `password` / `credential` / `cookie` /
  `authorization` / `*apiKey*` become a **boolean** (`true` if a value was
  supplied). Never pass a credential in any other key.
- Any key containing `token` becomes the literal `<redacted>`.
- `id`, any key ending in `Id` (camelCase) or `_id` (snake_case), including
  `hostId`, `clientId`, `sessionId`, `turnId`, `requestId`, `host_id` and
  `session_id`, is masked to a prefix plus last four characters. Counters
  (`muxGeneration`, `followEpoch`) stay readable: they identify a reconnect,
  not a person.
- Redaction markers are idempotent: `<redacted>` and boolean markers survive
  the bundle's second redaction pass unchanged.
- Oversized payloads keep a bounded, visibly marked prefix (`<payload
  truncated>`) and increment `droppedEvents`; nothing is silently cut. The
  shared redactor's log-oriented 2000-character line cut is bypassed for
  events, so a 2500-character single line survives until the payload cap.
- A `payload` that is a JSON object/array (or a JSON-shaped string) is
  sanitized by key, so a short `access_token` nested in it is still masked.

## Where to instrument (for the follow-up埋点 work)

- Agent switch / connect / disconnect: `app/lib/state/connection_state.dart`,
  `agent_selection_state.dart` — put `hostKind`, `hostId`, `agent`,
  `clientId`, `muxGeneration` on each event.
- Follow epoch / cache reuse / transcript loss: `app/lib/state/chat_state.dart`
  — put `sessionId`, `turnId`, `followEpoch`, `requestId`.
- Send failures and tool names: `app/lib/state/chat_state.dart`,
  `app/lib/ui/chat/**` — put `errorCode`, `errorMessage`, `toolName`,
  `durationMs`.
- Workspace selection: `app/lib/state/workspaces_state.dart` — put `payload:
  {'workspace': id}` (no raw path if it contains a username/secret).
- Dual-client lock: the remote SSH/relay link code — put `hostId`,
  `clientId`, `muxGeneration`, `errorCode`.

Always record right before swallowing an exception (the event log never
throws), and include `source` and a redacted `errorMessage`.

## Bundle wiring

- `app-events.json` is written unconditionally by `DiagnosticsBundle.entries`,
  `[]` when nothing was recorded.
- `summary.json` adds `connection.{hostId,hostKind,agent,clientId,sessionId,
  turnId,requestId,muxGeneration,followEpoch,connectedAt}` (null when the app
  has no such observation) and `appEvents.{count,droppedEvents,capacity}`.
- `summary.json` also carries the last engine `connection` observation
  (`host`, `state`, `link`, `observedAtEpochMs`) unchanged.
