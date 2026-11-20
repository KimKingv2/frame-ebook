import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/core/frame_api_client.dart';
import 'package:frame_ebook/core/frame_api_scope.dart';
import 'package:material_ui/material_ui.dart';

class _TestApi implements FrameApiClient {
  @override
  Future<Map<String, dynamic>> getJson(String path) async => const {};

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      const {};

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async =>
      const {};

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  ) async =>
      const {};

  @override
  Future<Uint8List> getBytes(String path) async => Uint8List(0);

  @override
  void close() {}
}

class _ScopeProbe extends StatelessWidget {
  const _ScopeProbe();

  @override
  Widget build(BuildContext context) {
    final api = FrameApiScope.of(context);
    return Scaffold(
      body: Center(
        child: Text(api is _TestApi ? 'scope-inherited' : 'wrong-api'),
      ),
    );
  }
}

void main() {
  testWidgets('copies FrameApiScope into a newly pushed Navigator route',
      (tester) async {
    final api = _TestApi();

    await tester.pumpWidget(
      MaterialApp(
        home: FrameApiScope(
          api: api,
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => FrameApiScope.inherit(
                          context: context,
                          child: const _ScopeProbe(),
                        ),
                      ),
                    );
                  },
                  child: const Text('開啟下一頁'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開啟下一頁'));
    await tester.pumpAndSettle();

    expect(find.text('scope-inherited'), findsOneWidget);
  });

  testWidgets('reports a useful error when no FrameApiScope exists',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Builder(
                builder: (innerContext) => FilledButton(
                  onPressed: () {
                    Navigator.of(innerContext).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => FrameApiScope.inherit(
                          context: innerContext,
                          child: const _ScopeProbe(),
                        ),
                      ),
                    );
                  },
                  child: const Text('開啟下一頁'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開啟下一頁'));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
  });
}
