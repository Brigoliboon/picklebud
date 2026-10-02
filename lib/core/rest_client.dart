import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class RestException implements Exception {
  RestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'RestException($statusCode): $message';
}

class VideoCameraSource {
  const VideoCameraSource({required this.index});

  final int index;
}

class VideoConnectResult {
  const VideoConnectResult({
    required this.kind,
    required this.source,
    required this.width,
    required this.height,
    this.fps,
    this.frameCount,
  });

  final String kind;
  final String source;
  final int width;
  final int height;
  final double? fps;
  final int? frameCount;

  String get label => '$source · ${width}x$height';
}

class VideoStatus {
  const VideoStatus({required this.connected, this.width, this.height});

  final bool connected;
  final int? width;
  final int? height;
}

class CourtPoint {
  const CourtPoint({required this.x, required this.y});

  final double x;
  final double y;

  List<double> toJson() => [x, y];

  static CourtPoint fromJson(Object? json) {
    final list = json as List;
    return CourtPoint(
      x: (list[0] as num).toDouble(),
      y: (list[1] as num).toDouble(),
    );
  }
}

class CourtDetectResult {
  const CourtDetectResult({
    required this.courtReady,
    required this.corners,
    required this.points,
    this.width,
    this.height,
  });

  final bool courtReady;
  final List<Map<String, dynamic>> corners;
  final List<CourtPoint> points;
  final int? width;
  final int? height;
}

class CourtState {
  const CourtState({
    required this.courtReady,
    required this.calibrated,
    required this.corners,
    this.width,
    this.height,
  });

  final bool courtReady;
  final bool calibrated;
  final List<CourtPoint> corners;
  final int? width;
  final int? height;
}

class RestClient {
  RestClient({
    http.Client? httpClient,
    this.baseUrl = defaultBaseUrl,
    this.timeout = const Duration(seconds: 5),
  }) : _httpClient = httpClient ?? http.Client();

  static const defaultBaseUrl = 'http://127.0.0.1:8790';

  final String baseUrl;
  final Duration timeout;
  final http.Client _httpClient;

  Future<void> health() async {
    await _get('/health');
  }

  Future<List<VideoCameraSource>> listCameras() async {
    final json = await _get('/video/sources') as Map<String, dynamic>;
    final cameras = json['cameras'] as List<dynamic>? ?? const [];
    return cameras
        .map((c) => VideoCameraSource(index: (c as num).toInt()))
        .toList();
  }

  Future<List<String>> listSamples() async {
    final json = await _get('/video/samples') as Map<String, dynamic>;
    final samples = json['samples'] as List<dynamic>? ?? const [];
    return samples.map((s) => s as String).toList();
  }

  Future<VideoConnectResult> connectCamera(int index) async {
    return _connect({'kind': 'camera', 'source': '$index'});
  }

  Future<VideoConnectResult> connectFile(String path) async {
    return _connect({'kind': 'file', 'source': path});
  }

  Future<CourtDetectResult> detectCourt() async {
    final json = await _post('/setup/detect-court', const {}) as Map<String, dynamic>;
    return CourtDetectResult(
      courtReady: json['court_ready'] as bool? ?? false,
      corners: (json['corners'] as List? ?? const [])
          .map((e) => e as Map<String, dynamic>)
          .toList(),
      points: (json['points'] as List? ?? const [])
          .map(CourtPoint.fromJson)
          .toList(),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }

  /// Still JPEG of the connected source for corner review/drag-adjust.
  Future<Uint8List> fetchSnapshot() async {
    final uri = _uri('/setup/snapshot');
    late http.Response response;
    try {
      response = await _httpClient.get(uri).timeout(timeout);
    } on TimeoutException {
      throw RestException('request timed out: GET /setup/snapshot');
    } on http.ClientException catch (e) {
      throw RestException('connection failed: ${e.message}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RestException(
        _extractDetail(response.body) ?? 'request failed: GET /setup/snapshot',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  /// Referee confirms the (possibly drag-adjusted) 4 court corners.
  /// Gates the live ball-tracking stream server-side.
  Future<void> confirmCourt(List<CourtPoint> corners) async {
    final json = await _post('/setup/confirm-court', {
      'corners': corners.map((c) => c.toJson()).toList(),
    }) as Map<String, dynamic>;
    if (json['status'] != 'calibrated') {
      throw RestException('court not calibrated');
    }
  }

  Future<CourtState> fetchCourt() async {
    final json = await _get('/setup/court') as Map<String, dynamic>;
    return CourtState(
      courtReady: json['court_ready'] as bool? ?? false,
      calibrated: json['calibrated'] as bool? ?? false,
      corners: (json['corners'] as List? ?? const [])
          .map(CourtPoint.fromJson)
          .toList(),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }

  Future<String> fetchPhase() async {
    final json = await _get('/match/phase') as Map<String, dynamic>;
    return json['phase'] as String? ?? 'IDLE';
  }

  Future<void> recalibrate() async {
    await _post('/match/recalibrate', const {});
  }

  Future<VideoConnectResult> _connect(Map<String, dynamic> body) async {
    final json = await _post('/video/connect', body) as Map<String, dynamic>;
    if (json['connected'] != true) {
      throw RestException('source not connected');
    }
    return VideoConnectResult(
      kind: json['kind'] as String,
      source: json['source'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      fps: (json['fps'] as num?)?.toDouble(),
      frameCount: (json['frame_count'] as num?)?.toInt(),
    );
  }

  Future<void> disconnect() async {
    await _post('/video/disconnect', const {});
  }

  Future<VideoStatus> videoStatus() async {
    final json = await _get('/video/status') as Map<String, dynamic>;
    return VideoStatus(
      connected: json['connected'] == true,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Object?> _get(String path) => _send('GET', path, {});

  Future<Object?> _post(String path, Map<String, dynamic> body) =>
      _send('POST', path, body);

  Future<Object?> _send(String method, String path, Map<String, dynamic> body) async {
    final uri = _uri(path);
    late http.Response response;
    try {
      if (method == 'GET') {
        response = await _httpClient.get(uri).timeout(timeout);
      } else {
        response = await _httpClient
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(timeout);
      }
    } on TimeoutException {
      throw RestException('request timed out: $method $path');
    } on http.ClientException catch (e) {
      throw RestException('connection failed: ${e.message}');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = _extractDetail(response.body);
      throw RestException(
        detail ?? 'request failed: $method $path',
        statusCode: response.statusCode,
      );
    }

    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw RestException('invalid JSON response from $path');
    }
  }

  String? _extractDetail(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic> && json['detail'] is String) {
        return json['detail'] as String;
      }
    } on FormatException {
      // ignore non-JSON bodies
    }
    return null;
  }

  void close() => _httpClient.close();
}