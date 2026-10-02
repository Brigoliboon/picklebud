import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pickleball/core/rest_client.dart';
import 'package:pickleball/core/sidecar.dart';
import 'package:pickleball/features/video_feed/video_feed_page.dart';
import 'package:pickleball/main.dart';
import 'package:pickleball/theme/app_theme.dart';

class _NoopSidecarManager extends SidecarManager {
  _NoopSidecarManager() : super();

  @override
  Future<void> launch() async {}

  @override
  Future<void> shutdown() async {}
}

RestClient _healthyClient() {
  return RestClient(
    baseUrl: 'http://test.local',
    httpClient: MockClient((request) async {
      switch (request.url.path) {
        case '/health':
          return http.Response('{"status":"ok"}', 200);
        case '/video/sources':
          return http.Response('{"cameras":[0,1,2]}', 200);
        case '/video/samples':
          return http.Response('{"samples":["/srv/sample1.mp4","/srv/sample2.mp4"]}', 200);
        case '/video/status':
          return http.Response('{"connected":true,"width":1280,"height":720}', 200);
        case '/video/connect':
          return http.Response(
            jsonEncode({
              'connected': true,
              'kind': request.body.contains('file') ? 'file' : 'camera',
              'source': request.body.contains('file') ? '/tmp/video.mp4' : '0',
              'width': 1280,
              'height': 720,
              'fps': 29.97,
              'frame_count': null,
            }),
            200,
          );
        case '/video/disconnect':
          return http.Response('{"disconnected":true}', 200);
        default:
          return http.Response('{"detail":"not found"}', 404);
      }
    }),
  );
}

Future<void> _pumpApp(WidgetTester tester, {RestClient? restClient}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: VideoFeedPage(
      restClient: restClient ?? _healthyClient(),
      sidecarManager: _NoopSidecarManager(),
    ),
  ));
}

void main() {
  testWidgets('app shell shows sidecar connected after health poll', (tester) async {
    await _pumpApp(tester);

    expect(find.text('Sidecar · Disconnected'), findsOneWidget);
    expect(find.text('Waiting for sidecar…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.text('Sidecar · Connected'), findsOneWidget);
    expect(find.text('Connect Source'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

testWidgets('camera dropdown reflects backend camera list', (tester) async {
    await _pumpApp(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    await tester.tap(find.text('Connect Source'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('1280x720'), findsWidgets);
    expect(find.textContaining('Starting preview'), findsOneWidget);

await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching to video file source shows file field', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.text('Video File'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.text('Video file path'), findsOneWidget);
    expect(find.text('Browse'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sample video chips fill the file path', (tester) async {
    await _pumpApp(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    await tester.tap(find.text('Video File'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.text('sample1.mp4'), findsOneWidget);
    expect(find.text('sample2.mp4'), findsOneWidget);

    await tester.tap(find.text('sample1.mp4'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, '/srv/sample1.mp4'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PickleballApp shell renders', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PickleballApp(
      restClient: _healthyClient(),
      sidecarManager: _NoopSidecarManager(),
    ));

    expect(find.text('Pickleball Court Analysis'), findsOneWidget);
    expect(find.text('Video Source'), findsOneWidget);

    // Drop the page to dispose timers.
    await tester.pumpWidget(const SizedBox());
  });
}