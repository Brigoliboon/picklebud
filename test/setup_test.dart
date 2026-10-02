import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pickleball/core/rest_client.dart';
import 'package:pickleball/core/sidecar.dart';
import 'package:pickleball/features/setup/court_calibration.dart';
import 'package:pickleball/features/video_feed/video_feed_page.dart';
import 'package:pickleball/theme/app_theme.dart';

class _NoopSidecarManager extends SidecarManager {
  _NoopSidecarManager() : super();

  @override
  Future<void> launch() async {}

  @override
  Future<void> shutdown() async {}
}

void main() {
  test('confirmCourt() posts 4 corners and parses calibrated', () async {
    final client = RestClient(
      httpClient: MockClient((req) async {
        expect(req.url.path, '/setup/confirm-court');
        final body = const JsonDecoder().convert(req.body);
        expect((body['corners'] as List), hasLength(4));
        return http.Response('{"status":"calibrated"}', 200,
            headers: {'content-type': 'application/json'});
      }),
      baseUrl: 'http://test.local',
    );
    await expectLater(
      client.confirmCourt(const [
        CourtPoint(x: 10, y: 10),
        CourtPoint(x: 100, y: 10),
        CourtPoint(x: 100, y: 100),
        CourtPoint(x: 10, y: 100),
      ]),
      completes,
    );
  });

  testWidgets('calibrator renders 4 draggable handles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: CourtCalibrationOverlay(
              initialCorners: const [
                Offset(10, 10),
                Offset(100, 10),
                Offset(100, 100),
                Offset(10, 100),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(ValueKey('court-handle-$i')), findsOneWidget);
    }
  });

  testWidgets('dragging a handle updates corners', (tester) async {
    List<Offset>? latest;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: CourtCalibrationOverlay(
              initialCorners: const [
                Offset(10, 10),
                Offset(100, 10),
                Offset(100, 100),
                Offset(10, 100),
              ],
              onChanged: (corners) => latest = corners,
            ),
          ),
        ),
      ),
    );
    await tester.drag(
        find.byKey(const ValueKey('court-handle-0')), const Offset(20, 15));
    await tester.pump();
    expect(latest, isNotNull);
    expect(latest![0].dx, closeTo(30, 1.0));
    expect(latest![0].dy, closeTo(25, 1.0));
  });

  testWidgets('partial detection shows reposition dialog, no guessed corners',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final rest = RestClient(
      baseUrl: 'http://test.local',
      httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/health':
            return http.Response('{"status":"ok"}', 200);
          case '/video/sources':
            return http.Response('{"cameras":[0]}', 200);
          case '/video/samples':
            return http.Response('{"samples":[]}', 200);
          case '/video/connect':
            return http.Response(
              const JsonEncoder().convert({
                'connected': true,
                'kind': 'camera',
                'source': '0',
                'width': 1280,
                'height': 720,
                'fps': 30.0,
                'frame_count': null,
              }),
              200,
            );
          case '/video/disconnect':
            return http.Response('{"disconnected":true}', 200);
          case '/setup/snapshot':
            return http.Response.bytes([0xFF, 0xD8, 0xFF, 0xD9], 200);
          case '/setup/detect-court':
            // Only 3 of 4 corners visible.
            return http.Response(
              const JsonEncoder().convert({
                'court_ready': false,
                'corners': [],
                'points': [
                  [100, 100],
                  [200, 100],
                  [100, 200],
                ],
                'width': 1280,
                'height': 720,
              }),
              200,
            );
          default:
            return http.Response('{"detail":"not found"}', 404);
        }
      }),
    );
    addTearDown(rest.close);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: VideoFeedPage(
        restClient: rest,
        sidecarManager: _NoopSidecarManager(),
      ),
    ));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    await tester.tap(find.text('Connect Source'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('1 · Detect Court'));
    // Bounded pumps: the flow is non-blocking, and pumpAndSettle would hang
    // on the detached stream-close timeout timer (fires at 3s, harmless).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Court not fully visible'), findsOneWidget);
    expect(find.textContaining('3 of 4'), findsOneWidget);
    // No calibrator and no confirmable state.
    expect(find.byKey(const ValueKey('court-handle-0')), findsNothing);

    // Let the detached stream-close timeout elapse so no timer is pending.
    await tester.pump(const Duration(seconds: 4));

    await tester.pumpWidget(const SizedBox());
  });
}
