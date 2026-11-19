/// Value-level tests for the AGY model catalog projection.
/// No network, no carrier start-up: every assertion below runs
/// against pure functions in `agy_values.dart` / `agy_history.dart`.
///
/// 私有方法，通过公开投影覆盖等价逻辑: `_modelsFor` (agy_virtual.dart) is
/// private, so its degradation branches are asserted through the public
/// projections they delegate to (`agyModelCatalogProjection` and
/// `agyEmptyModelCatalog`).
library;

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

Map<String, Object?> _rawCatalog() => <String, Object?>{
      'current': <String, Object?>{'provider': agyBackend, 'model': 'gemini-3-pro', 'reasoningEffort': 'high'},
      'routable': true,
      'groups': <Object?>[
        <String, Object?>{
          'id': agyBackend,
          'name': 'Antigravity',
          'models': <Object?>[
            <String, Object?>{'id': 'gemini-3-pro-high', 'name': 'Gemini 3 Pro (High)', 'description': 'flagship'},
          ],
        },
      ],
      'failures': <Object?>[
        <String, Object?>{'provider': 'other', 'message': 'boom'},
      ],
    };

/// One group whose six wire ids differ only by effort suffix.
Map<String, Object?> _effortCatalog() => <String, Object?>{
      'current': <String, Object?>{'provider': agyBackend, 'model': 'gemini-3-pro'},
      'groups': <Object?>[
        <String, Object?>{
          'id': agyBackend,
          'name': 'Antigravity',
          'models': <Object?>[
            for (final effort in <String>['low', 'medium', 'high', 'xhigh', 'max', 'thinking'])
              <String, Object?>{'id': 'gemini-3-pro-$effort', 'name': 'Gemini 3 Pro ($effort)'},
          ],
        },
      ],
    };

void main() {
  group('agyModelCatalogProjection', () {
    test('keeps the group, default and failure shape of a typical AGY payload', () {
      final projected = agyModelCatalogProjection(_rawCatalog());

      expect(
        projected['default'],
        <String, Object?>{'provider': agyBackend, 'model': 'gemini-3-pro', 'reasoningEffort': 'high'},
      );
      expect(projected['routableProviders'], <Object?>[agyBackend]);
      expect(projected['failures'], <Object?>[
        <String, Object?>{'provider': 'other', 'message': 'boom'},
      ]);

      final groups = projected['groups']! as List<Object?>;
      expect(groups, hasLength(1));
      final group = groups.single! as Map<String, Object?>;
      expect(group['id'], agyBackend);
      expect(group['name'], 'Antigravity');

      final models = group['models']! as List<Object?>;
      expect(models, hasLength(1));
      expect(models.single, <String, Object?>{
        'id': 'gemini-3-pro',
        'name': 'Gemini 3 Pro',
        'description': 'flagship',
        'provider': agyBackend,
        'reasoning': <String, Object?>{
          'efforts': <Object?>[
            <String, Object?>{'id': 'high', 'name': 'High'},
          ],
          'defaultEffort': 'high',
        },
      });
    });

    test('null and non-map input degrade quietly to an empty catalog', () {
      for (final raw in <Object?>[null, 'not-a-map', 42, <String, Object?>{}]) {
        final projected = agyModelCatalogProjection(raw);
        expect(projected['default'], isEmpty);
        expect(projected['groups'], isEmpty);
        expect(projected['failures'], isEmpty);
        // `routable` defaults to true, so the AGY provider stays routable.
        expect(projected['routableProviders'], <Object?>[agyBackend]);
      }
    });

    test('a payload without `current` projects an empty default', () {
      final projected = agyModelCatalogProjection(<String, Object?>{
        'groups': <Object?>[],
        'routable': false,
      });
      expect(projected['default'], isEmpty);
      expect(projected['routableProviders'], isEmpty);
    });

    test('collapses the six effort suffixes into one row in stable order', () {
      final groups = agyModelCatalogProjection(_effortCatalog())['groups']! as List<Object?>;
      final models = (groups.single! as Map<String, Object?>)['models']! as List<Object?>;
      expect(models, hasLength(1));

      final model = models.single! as Map<String, Object?>;
      expect(model['id'], 'gemini-3-pro');
      final reasoning = model['reasoning']! as Map<String, Object?>;
      expect(reasoning['efforts'], <Object?>[
        <String, Object?>{'id': 'low', 'name': 'Low'},
        <String, Object?>{'id': 'medium', 'name': 'Medium'},
        <String, Object?>{'id': 'high', 'name': 'High'},
        <String, Object?>{'id': 'xhigh', 'name': 'Xhigh'},
        <String, Object?>{'id': 'max', 'name': 'Max'},
        <String, Object?>{'id': 'thinking', 'name': 'Thinking'},
      ]);
      expect(reasoning['defaultEffort'], 'low');
    });
  });

  group('agyParseModelVariant', () {
    test('splits each of the six official suffixes', () {
      for (final effort in <String>['low', 'medium', 'high', 'xhigh', 'max', 'thinking']) {
        final variant = agyParseModelVariant('gemini-3-pro-$effort');
        expect(variant, isNotNull, reason: 'suffix $effort must parse');
        expect(variant!.id, 'gemini-3-pro');
        expect(variant.effort, effort);
        expect(variant.wireId, 'gemini-3-pro-$effort');
      }
    });

    test('leaves unsuffixed or too-short ids alone', () {
      expect(agyParseModelVariant('gemini-3-pro'), isNull);
      expect(agyParseModelVariant('high'), isNull);
      expect(agyParseModelVariant('-high'), isNull);
    });

    test('strips the display-name suffix the same way', () {
      expect(agyStripEffortName('Gemini 3 Pro (High)'), 'Gemini 3 Pro');
      expect(agyStripEffortName('Gemini 3 Pro (Thinking)'), 'Gemini 3 Pro');
      expect(agyStripEffortName('Gemini 3 Pro'), 'Gemini 3 Pro');
    });
  });

  group('agyEmptyModelCatalog', () {
    test('is the host-settings stub the no-session branch returns', () {
      final stub = agyEmptyModelCatalog();
      expect(stub['default'], <String, Object?>{'provider': agyBackend, 'model': 'host-settings'});
      expect(stub['routableProviders'], isEmpty);
      expect(stub['failures'], isEmpty);
      final groups = stub['groups']! as List<Object?>;
      expect(groups, hasLength(1));
      final group = groups.single! as Map<String, Object?>;
      expect(group['id'], agyBackend);
      expect(group['name'], 'Antigravity');
      expect(group['models'], isEmpty);
    });
  });
}
