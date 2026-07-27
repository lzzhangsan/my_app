import 'package:change_copy/smart_download/smart_action_parts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit left flick survives JSON round trip', () {
    final original = SmartActionStep(kind: SmartActionKind.flickLeft);
    final restored = SmartActionStep.fromJson(original.toJson());

    expect(restored.kind, SmartActionKind.flickLeft);
    expect(restored.kind.id, 'flick_left');
  });

  test('horizontal next-media action survives recipe round trip', () {
    final recipe = SmartActionRecipe(
      host: 'm.facebook.com',
      name: 'images',
      advanceAxisHint: 'left',
      steps: <SmartActionStep>[
        SmartActionStep(kind: SmartActionKind.longPressDownload),
        SmartActionStep(kind: SmartActionKind.waitDownload),
        SmartActionStep(kind: SmartActionKind.findNextMediaRight),
      ],
    );
    final restored = SmartActionRecipe.fromJson(recipe.toJson());

    expect(restored.advanceAxisHint, 'left');
    expect(restored.steps.last.kind, SmartActionKind.findNextMediaRight);
  });
}
