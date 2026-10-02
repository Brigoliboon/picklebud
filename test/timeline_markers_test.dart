import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball/core/frame_stream_client.dart';
import 'package:pickleball/core/timeline_markers.dart';

FrameHeader _header({
  required double timestamp,
  required int frameIndex,
  required List<String> events,
}) {
  final detections = '[]';
  return FrameHeader.fromJson(
    '{"type":"frame","frame_index":$frameIndex,"timestamp":$timestamp,'
    '"width":1280,"height":720,"detections":$detections,'
    '"events":[${events.map((e) => '"$e"').join(',')}]}',
  );
}

void main() {
  test('bounce and exit events accumulate as typed markers', () {
    final log = TimelineMarkerLog();
    log.addFromHeader(_header(
        timestamp: 10, frameIndex: 100, events: ['ball_bounce_near_boundary']));
    log.addFromHeader(
        _header(timestamp: 12, frameIndex: 120, events: ['ball_exit_boundary']));
    log.addFromHeader(_header(timestamp: 13, frameIndex: 130, events: ['none']));

    expect(log.markers, hasLength(2));
    expect(log.bounceCount, 1);
    expect(log.exitCount, 1);
    expect(log.markers.first.type, MarkerType.bounce);
    expect(log.markers.last.timestamp, 12);
  });

  test('preview and empty events are ignored', () {
    final log = TimelineMarkerLog();
    log.addFromHeader(_header(timestamp: 1, frameIndex: 1, events: []));
    expect(log.markers, isEmpty);
  });

  test('history is bounded and clearable', () {
    final log = TimelineMarkerLog(maxMarkers: 3);
    for (var i = 0; i < 5; i++) {
      log.addFromHeader(_header(
          timestamp: i.toDouble(),
          frameIndex: i,
          events: ['ball_bounce_near_boundary']));
    }
    expect(log.markers, hasLength(3));
    log.clear();
    expect(log.markers, isEmpty);
  });
}
