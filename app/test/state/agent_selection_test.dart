// The Agent choice is a single value per Host: switching it reconnects, so it
// is stored per Host (never as a filter over a merged list).

import 'dart:convert';

import 'package:dsh_app/state/agent_capabilities_state.dart';
import 'package:dsh_app/state/agent_selection_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show ActiveHostController, HostRef, activeHostProvider;
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AgentSelection', () {
    test('an unknown Host is DSH', () {
      const selection = AgentSelection();
      expect(selection.forHost('h1'), RemoteAgent.dsh);
      expect(selection.forHost(null), RemoteAgent.dsh);
      expect(selection.forHost(''), RemoteAgent.dsh);
    });

    test('per-Host choices do not leak into another Host', () {
      final selection = const AgentSelection().withHost('h1', RemoteAgent.codex);
      expect(selection.forHost('h1'), RemoteAgent.codex);
      expect(selection.forHost('h2'), RemoteAgent.codex, reason: 'the last choice is the default');
      final again = selection.withHost('h2', RemoteAgent.agy);
      expect(again.forHost('h1'), RemoteAgent.codex);
      expect(again.forHost('h2'), RemoteAgent.agy);
    });

    test('JSON round-trips codes and falls back to DSH', () {
      final encoded = json.encode(const AgentSelection().withHost('h1', RemoteAgent.agy).toJson());
      final decoded = AgentSelection.fromJson(json.decode(encoded));
      expect(decoded.forHost('h1'), RemoteAgent.agy);
      expect(decoded.defaultAgent, RemoteAgent.agy);

      expect(AgentSelection.fromJson(null).forHost('h1'), RemoteAgent.dsh);
      expect(AgentSelection.fromJson('damaged').forHost('h1'), RemoteAgent.dsh);
      expect(
        AgentSelection.fromJson(<String, Object?>{
          'default': 'GPT',
          'hosts': <String, Object?>{'h1': 'nope'},
        }).forHost('h1'),
        RemoteAgent.dsh,
      );
    });

    test('RemoteAgent.parse accepts the wire codes and rejects the rest', () {
      expect(RemoteAgent.parse('CodeX'), RemoteAgent.codex);
      expect(RemoteAgent.parse(' CodeX '), RemoteAgent.codex);
      expect(RemoteAgent.parse('AGY'), RemoteAgent.agy);
      expect(RemoteAgent.parse('codex'), RemoteAgent.dsh);
      expect(RemoteAgent.parse(null), RemoteAgent.dsh);
    });
  });

  group('AgentSelectionController', () {
    test('select persists the Host choice and is a no-op for the same Agent', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(agentSelectionProvider.notifier);
      await notifier.ready();
      expect(container.read(agentSelectionProvider).forHost('h1'), RemoteAgent.dsh);

      await notifier.select('h1', RemoteAgent.codex);
      expect(container.read(agentSelectionProvider).forHost('h1'), RemoteAgent.codex);

      await notifier.select('h1', RemoteAgent.codex);
      final prefs = await SharedPreferences.getInstance();
      expect(json.decode(prefs.getString(agentSelectionPrefsKey)!)['hosts'], <String, Object>{'h1': 'CodeX'});

      await notifier.select('', RemoteAgent.agy);
      expect(container.read(agentSelectionProvider).forHost(''), RemoteAgent.dsh);
    });

    test('a stored choice is read back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        agentSelectionPrefsKey: json.encode(<String, Object?>{
          'default': 'AGY',
          'hosts': <String, Object?>{'h1': 'CodeX'},
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(agentSelectionProvider.notifier).ready();
      final state = container.read(agentSelectionProvider);
      expect(state.forHost('h1'), RemoteAgent.codex);
      expect(state.forHost('h2'), RemoteAgent.agy);
      expect(state.forHost(null), RemoteAgent.dsh);
    });
  });

  group('AgentCapabilities', () {
    test('virtual Agents drop the DSH-only surfaces and keep the shared ones', () {
      for (final caps in <AgentCapabilities>[AgentCapabilities.codex, AgentCapabilities.agy]) {
        expect(caps.bots, isFalse);
        expect(caps.teams, isFalse);
        expect(caps.plugins, isFalse);
        expect(caps.schedules, isFalse);
        expect(caps.terminal, isFalse);
        expect(caps.jobs, isFalse);
        expect(caps.skills, isFalse);
        expect(caps.subagents, isFalse);
        expect(caps.tokenUsage, isFalse);
        expect(caps.archive, isFalse, reason: 'neither virtual Agent implements session archive');
        expect(caps.models, isTrue);
        expect(caps.permissions, isTrue);
        expect(caps.attachments, isTrue);
        expect(caps.rename, isTrue);
        expect(caps.fork, isTrue);
        expect(caps.workspaceFiles, isTrue);
        expect(caps.supportsFeature('models'), isTrue);
        expect(caps.supportsFeature('ds-bot'), isFalse);
        expect(caps.supportsFeature('plugin-panel:x#y'), isFalse, reason: 'unknown ids are DSH-only');
      }
    });

    test('DSH keeps everything and never reports an unsupported known entry', () {
      final caps = AgentCapabilities.dsh;
      expect(caps.archive, isTrue);
      for (final id in <String>[
        'session-detail',
        'artifacts',
        'files',
        'terminal',
        'export',
        'jobs',
        'plan-goal',
        'skills',
        'subagents',
        'reference',
        'schedules',
        'token-usage',
        'plugins',
        'cordis',
        'agent-team',
        'ds-bot',
        'share-profile',
        'web',
        'models',
        'permission',
        'workspaces',
      ]) {
        expect(caps.supportsFeature(id), isTrue, reason: id);
      }
    });

    test('AGY and CodeX report the same known entries', () {
      for (final id in <String>['files', 'models', 'permission', 'workspaces', 'search', 'remote', 'phone', 'forum']) {
        expect(AgentCapabilities.agy.supportsFeature(id), isTrue, reason: id);
        expect(AgentCapabilities.codex.supportsFeature(id), isTrue, reason: id);
      }
    });
  });

  group('activeAgentProvider', () {
    test('a relay Host uses the stored Agent', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        agentSelectionPrefsKey: json.encode(<String, Object?>{
          'default': 'CodeX',
          'hosts': <String, Object?>{'h1': 'AGY'},
        }),
      });
      final container = ProviderContainer(
        overrides: [activeHostProvider.overrideWith(() => _FixedHost(HostRef.relay('h1')))],
      );
      addTearDown(container.dispose);
      await container.read(agentSelectionProvider.notifier).ready();
      expect(container.read(activeAgentProvider), RemoteAgent.agy);
    });

    test('local and SSH Hosts always use DSH', () {
      for (final host in <HostRef>[HostRef.local, HostRef.ssh('h1')]) {
        final container = ProviderContainer(overrides: [activeHostProvider.overrideWith(() => _FixedHost(host))]);
        addTearDown(container.dispose);
        expect(container.read(activeAgentProvider), RemoteAgent.dsh);
      }
    });
  });
}

class _FixedHost extends ActiveHostController {
  _FixedHost(this.host);
  final HostRef host;

  @override
  HostRef build() => host;
}
