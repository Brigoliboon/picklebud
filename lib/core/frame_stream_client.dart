import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A single detection from the analysis sidecar.
class FrameDetection {
  const FrameDetection({
    required this.label,
    required this.classId,
    required this.confidence,
    required this.box,
    required this.center,
    required this.isCourt,
  });

  final String label;
  final int classId;
  final double confidence;

  /// [x1, y1, x2, y2] in original-frame pixel coordinates.
  final List<int> box;
  final List<int> center;
  final bool isCourt;

  factory FrameDetection.fromJson(Map<String, dynamic> json) {
    return FrameDetection(
      label: json['label'] as String? ?? '',
      classId: json['class_id'] as int? ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      box: (json['box'] as List?)?.map((e) => e as int).toList() ?? const [],
      center: (json['center'] as List?)?.map((e) => e as int).toList() ?? const [],
      isCourt: json['is_court'] as bool? ?? false,
    );
  }
}

/// Metadata for one analyzed frame; the JPEG bytes arrive in a following message.
class FrameHeader {
  const FrameHeader({
    required this.type,
    required this.frameIndex,
    required this.timestamp,
    required this.width,
    required this.height,
    required this.detections,
    required this.events,
  });

  final String type;
  final int frameIndex;
  final double timestamp;
  final int width;
  final int height;
  final List<FrameDetection> detections;
  final List<String> events;

  factory FrameHeader.fromJson(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return FrameHeader(
      type: json['type'] as String? ?? 'frame',
      frameIndex: json['frame_index'] as int? ?? 0,
      timestamp: (json['timestamp'] as num?)?.toDouble() ?? 0,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      detections: (json['detections'] as List? ?? const [])
          .map((e) => FrameDetection.fromJson(e as Map<String, dynamic>))
          .toList(),
      events: (json['events'] as List? ?? const [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

/// Emitted when a full analyzed frame is received.
class AnalyzedFrame {
  const AnalyzedFrame({
    required this.header,
    required this.jpegBytes,
  });

  final FrameHeader header;
  final List<int> jpegBytes;
}

/// Reads the sidecar frame WebSockets: a JSON header string followed by
/// a binary JPEG frame per frame.
class FrameStreamClient {
  FrameStreamClient({String? url}) : _url = url ?? 'ws://127.0.0.1:8790/live/frames?fps=15';

  /// Raw preview stream: plain frames, no inference, no calibration gate.
  factory FrameStreamClient.preview() =>
      FrameStreamClient(url: 'ws://127.0.0.1:8790/live/preview?fps=15');

  final String _url;
  WebSocketChannel? _channel;
  FrameHeader? _pending;

  Stream<AnalyzedFrame> connect() {
    final channel = WebSocketChannel.connect(Uri.parse(_url));
    _channel = channel;
    final controller = StreamController<AnalyzedFrame>();

    late final StreamSubscription<dynamic> sub;
    sub = channel.stream.listen(
      (message) {
        if (message is String) {
          final header = FrameHeader.fromJson(message);
          if (header.type == 'end') {
            controller.close();
          } else {
            _pending = header;
          }
        } else if (message is List<int>) {
          final header = _pending;
          if (header != null) {
            controller.add(AnalyzedFrame(header: header, jpegBytes: message));
            _pending = null;
          }
        }
      },
      onError: (Object e, StackTrace st) => controller.addError(e, st),
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );

    controller.onCancel = () async {
      await sub.cancel();
      await channel.sink.close();
      _pending = null;
    };
    return controller.stream;
  }

  Future<void> disconnect() async {
    await _channel?.sink.close();
    _channel = null;
    _pending = null;
  }
}