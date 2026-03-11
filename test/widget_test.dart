// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:barcode_logger/main.dart';

void main() {
  testWidgets('app starts with single page camera and records', (WidgetTester tester) async {
    await tester.pumpWidget(const BarcodeLoggerApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Barcode Logger'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
