import 'package:flutter_test/flutter_test.dart';

import 'package:mac_process_terminator/main.dart';

void main() {
  testWidgets('应用能正常启动', (WidgetTester tester) async {
    await tester.pumpWidget(const ProcessTerminatorApp());
    await tester.pump();

    expect(find.text('到点关 · 进程定时关闭'), findsOneWidget);
  });
}
