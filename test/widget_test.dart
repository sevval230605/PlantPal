import 'package:flutter_test/flutter_test.dart';
import 'package:plantpal/main.dart';

void main() {
  testWidgets('PlantPal uygulaması açılıyor', (WidgetTester tester) async {
    await tester.pumpWidget(const PlantPalApp());

    expect(find.text('PlantPal'), findsOneWidget);
  });
}