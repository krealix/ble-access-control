import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ble_beacon_app/main.dart';

void main() {
  testWidgets('App boots and shows bluetooth icon', (WidgetTester tester) async {
    await tester.pumpWidget(const BleBeaconApp());
    expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
  });
}
