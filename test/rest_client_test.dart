import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pickleball/core/rest_client.dart';

void main() {
  RestClient clientWith(MockClient mock) =>
      RestClient(httpClient: mock, baseUrl: 'http://test.local');

  MockClient jsonClient(Map<String, dynamic> Function(http.Request req) handler) {
    return MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response('{"status":"ok"}', 200);
      }
      final body = handler(request);
      return http.Response(
        const JsonEncoder().convert(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }

  test('health() succeeds on ok response', () async {
    final client = clientWith(MockClient((req) async {
      expect(req.method, 'GET');
      expect(req.url.path, '/health');
      return http.Response('{"status":"ok"}', 200);
    }));

    await expectLater(client.health(), completes);
  });

  test('listCameras() parses camera indices', () async {
    final client = clientWith(jsonClient((req) {
      expect(req.url.path, '/video/sources');
      return {'cameras': [0, 1, 3]};
    }));

    final cameras = await client.listCameras();
    expect(cameras.map((c) => c.index), [0, 1, 3]);
  });

  test('connectCamera() posts kind/source and parses result', () async {
    final client = clientWith(jsonClient((req) {
      expect(req.method, 'POST');
      expect(req.url.path, '/video/connect');
      final body = const JsonDecoder().convert(req.body);
      expect(body, {'kind': 'camera', 'source': '2'});
      return {
        'connected': true,
        'kind': 'camera',
        'source': '2',
        'width': 1280,
        'height': 720,
        'fps': 29.97,
        'frame_count': null,
      };
    }));

    final result = await client.connectCamera(2);
    expect(result.kind, 'camera');
    expect(result.source, '2');
    expect(result.width, 1280);
    expect(result.height, 720);
    expect(result.fps, closeTo(29.97, 0.001));
    expect(result.frameCount, isNull);
  });

  test('connectFile() uses provided path', () async {
    final client = clientWith(jsonClient((req) {
      final body = const JsonDecoder().convert(req.body);
      expect(body, {'kind': 'file', 'source': '/tmp/video.mp4'});
      return {
        'connected': true,
        'kind': 'file',
        'source': '/tmp/video.mp4',
        'width': 1920,
        'height': 1080,
        'fps': 60.0,
        'frame_count': 1000,
      };
    }));

    final result = await client.connectFile('/tmp/video.mp4');
    expect(result.label, '/tmp/video.mp4 · 1920x1080');
    expect(result.frameCount, 1000);
  });

  test('non-2xx response surfaces RestException with statusCode', () async {
    final client = clientWith(MockClient((req) async {
      return http.Response('{"detail":"video file not found: /nope.mp4"}', 404);
    }));

    await expectLater(
      client.connectFile('/nope.mp4'),
      throwsA(isA<RestException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', contains('not found'))),
    );
  });

  test('disconnect() posts and completes', () async {
    final client = clientWith(jsonClient((req) {
      expect(req.method, 'POST');
      expect(req.url.path, '/video/disconnect');
      return {'disconnected': true};
    }));

    await expectLater(client.disconnect(), completes);
  });

  test('videoStatus() parses connected state', () async {
    final client = clientWith(jsonClient((req) {
      expect(req.url.path, '/video/status');
      return {'connected': true, 'width': 1280, 'height': 720};
    }));

    final status = await client.videoStatus();
    expect(status.connected, isTrue);
    expect(status.width, 1280);
    expect(status.height, 720);
  });
}