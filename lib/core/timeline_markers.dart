import 'frame_stream_client.dart';

/// Event kinds pinned on the live timeline strip.
enum MarkerType { bounce, exit }

/// One bookmarked moment: a bounce near the boundary (yellow) or a ball
/// crossing out of the court (red), at a video timestamp in seconds.
class TimelineMarker {
  const TimelineMarker({
    required this.timestamp,
    required this.frameIndex,
    required this.type,
  });

  final double timestamp;
  final int frameIndex;
  final MarkerType type;
}

/// Accumulates single-shot sidecar events into timeline markers.
/// "none" and empty (preview) event lists are ignored; history is bounded.
class TimelineMarkerLog {
  TimelineMarkerLog({this.maxMarkers = 500});

  final int maxMarkers;
  final List<TimelineMarker> _markers = [];

  List<TimelineMarker> get markers => List.unmodifiable(_markers);

  int get bounceCount => _markers.where((m) => m.type == MarkerType.bounce).length;

  int get exitCount => _markers.where((m) => m.type == MarkerType.exit).length;

  void addFromHeader(FrameHeader header) {
    for (final event in header.events) {
      switch (event) {
        case 'ball_bounce_near_boundary':
          _markers.add(TimelineMarker(
            timestamp: header.timestamp,
            frameIndex: header.frameIndex,
            type: MarkerType.bounce,
          ));
        case 'ball_exit_boundary':
          _markers.add(TimelineMarker(
            timestamp: header.timestamp,
            frameIndex: header.frameIndex,
            type: MarkerType.exit,
          ));
      }
    }
    if (_markers.length > maxMarkers) {
      _markers.removeRange(0, _markers.length - maxMarkers);
    }
  }

  void clear() => _markers.clear();
}
