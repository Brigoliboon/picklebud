import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/frame_stream_client.dart';
import '../../core/rest_client.dart';
import '../../core/sidecar.dart';
import '../../core/timeline_markers.dart';
import '../../theme/app_theme.dart';
import '../setup/court_calibration.dart';

enum VideoSourceKind { camera, file }

class VideoFeedPage extends StatefulWidget {
  const VideoFeedPage({super.key, this.restClient, this.sidecarManager});

  final RestClient? restClient;
  final SidecarManager? sidecarManager;

  @override
  State<VideoFeedPage> createState() => _VideoFeedPageState();
}

class _VideoFeedPageState extends State<VideoFeedPage> {
  static const _pollInterval = Duration(seconds: 3);

  late final RestClient _rest;
  late final SidecarManager _sidecar;

  Timer? _pollTimer;
  bool _polling = false;

  bool _sidecarConnected = false;
  bool _connecting = false;
  List<int> _cameraList = const [];
  List<String> _samples = const [];
  VideoConnectResult? _connected;

  FrameStreamClient? _frameStream;
  StreamSubscription<AnalyzedFrame>? _frameSub;
  Uint8List? _latestFrame;
  FrameHeader? _latestHeader;
  bool _endOfStream = false;

  ui.Image? _decodedFrame;
  ui.Image? _retiredFrame;
  bool _decoding = false;

  VideoSourceKind _kind = VideoSourceKind.camera;
  int _cameraIndex = 0;
  final TextEditingController _filePathController = TextEditingController();

  bool _detectingCourt = false;
  bool _courtReady = false;
  int _courtCorners = 0;

  // Calibration gate: connect → detect/adjust corners → confirm → stream.
  // The ball-tracking WebSocket must not start before court confirmation.
  Uint8List? _calibrationImage;
  List<Offset> _calibrationCorners = const [];
  int? _snapshotWidth;
  int? _snapshotHeight;
  bool _confirmingCourt = false;
  bool _calibrated = false;
  bool _streaming = false;
  bool _previewing = false;
  final TimelineMarkerLog _markerLog = TimelineMarkerLog();

  @override
  void initState() {
    super.initState();
    _rest = widget.restClient ?? RestClient();
    _sidecar = widget.sidecarManager ?? SidecarManager();
    _sidecar.launch();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollHealth());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _frameSub?.cancel();
    _frameStream?.disconnect();
    _retiredFrame?.dispose();
    _decodedFrame?.dispose();
    _sidecar.shutdown();
    _filePathController.dispose();
    super.dispose();
  }

  Future<void> _pollHealth() async {
    if (_polling) return;
    _polling = true;
    bool healthy = false;
    try {
      await _rest.health();
      healthy = true;
    } on RestException {
      healthy = false;
    } finally {
      _polling = false;
    }
    if (!mounted) return;

    if (healthy) {
      await _loadCamerasIfChanged();
    }
    if (_sidecarConnected != healthy) {
      setState(() => _sidecarConnected = healthy);
    }
  }

  Future<void> _loadCamerasIfChanged() async {
    try {
      final cameras = await _rest.listCameras();
      final samples = await _rest.listSamples();
      final indices = cameras.map((c) => c.index).toList();
      if (!mounted) return;
      if (_cameraList.length != indices.length ||
          !_cameraList.every(indices.contains)) {
        final top = indices.isNotEmpty
            ? indices.first
            : (_cameraIndex >= 0 ? _cameraIndex : 0);
        setState(() {
          _cameraList = indices;
          _cameraIndex = top;
        });
      }
      if (_samples.length != samples.length ||
          !_samples.every(samples.contains)) {
        setState(() => _samples = samples);
      }
    } on RestException {
      // transient failure is fine; keep last-known list
    }
  }

  void _onKindChanged(VideoSourceKind kind) {
    setState(() {
      _kind = kind;
      if (kind == VideoSourceKind.camera && _cameraList.isNotEmpty) {
        _cameraIndex = _cameraList.first;
      }
    });
  }

  void _onCameraChanged(int? index) {
    if (index != null) setState(() => _cameraIndex = index);
  }

  Future<void> _onConnectPressed() async {
    if (!_sidecarConnected) {
      _showSnack('Sidecar is not connected yet.');
      return;
    }
    setState(() => _connecting = true);
    try {
      final result = _kind == VideoSourceKind.camera
          ? await _rest.connectCamera(_cameraIndex)
          : await _rest.connectFile(_filePathController.text.trim());
      if (!mounted) return;
      setState(() {
        _connected = result;
        _markerLog.clear();
        _latestFrame = null;
        _latestHeader = null;
        _endOfStream = false;
        _calibrationImage = null;
        _calibrationCorners = const [];
        _calibrated = false;
        _streaming = false;
        _courtReady = false;
        _courtCorners = 0;
      });
      _startPreviewStream();
      _showSnack('Connected: ${result.kind} ${result.source} — live preview, no analysis yet.');
    } on RestException catch (e) {
      if (!mounted) return;
      setState(() => _connected = null);
      _showSnack('Connect failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

void _startFrameStream() {
    final client = FrameStreamClient();
    _frameStream = client;
    _frameSub?.cancel();
    setState(() {
      _streaming = true;
      _previewing = false;
      _endOfStream = false;
    });
    _frameSub = client.connect().listen(
      (analyzed) {
        if (!mounted) return;
        _latestFrame = Uint8List.fromList(analyzed.jpegBytes);
        _latestHeader = analyzed.header;
        _markerLog.addFromHeader(analyzed.header);
        _scheduleDecode();
      },
      onError: (error) {
        if (!mounted) return;
        _showSnack('Frame stream error: $error');
      },
      onDone: () => _onStreamDone(preview: false),
    );
  }

  void _startPreviewStream() {
    final client = FrameStreamClient.preview();
    _frameStream = client;
    _frameSub?.cancel();
    setState(() {
      _previewing = true;
      _streaming = false;
      _latestFrame = null;
      _latestHeader = null;
      _endOfStream = false;
    });
    _frameSub = client.connect().listen(
      (analyzed) {
        if (!mounted) return;
        if (analyzed.header.type == 'error') {
          _showSnack('Preview error: stream refused.');
          return;
        }
        _latestFrame = Uint8List.fromList(analyzed.jpegBytes);
        _latestHeader = analyzed.header;
        _scheduleDecode();
      },
      onError: (error) {
        if (!mounted) return;
        _showSnack('Preview stream error: $error');
      },
      onDone: () => _onStreamDone(preview: true),
    );
  }

  void _onStreamDone({required bool preview}) {
    if (!mounted) return;
    final active = preview ? _previewing : _streaming;
    if (!active) return; // stopped intentionally (disconnect/recalibrate)
    setState(() {
      _previewing = false;
      _streaming = false;
      _endOfStream = true;
    });
    _showSnack('End of video file reached.');
  }

  /// Decodes at most one frame at a time, always the newest received. Spawning
  /// a decode per incoming frame saturates the engine's decoder, so nothing
  /// renders while streaming — coalescing to the latest frame fixes that.
  void _scheduleDecode() {
    final bytes = _latestFrame;
    if (bytes == null || _decoding) return;
    _decoding = true;
    ui.decodeImageFromList(bytes, (ui.Image? image) {
      _decoding = false;
      if (!mounted) return;
      if (image != null) {
        setState(() {
          // Dispose only after the image is retired (a frame can still be
          // scheduled for paint when the next decode lands).
          _retiredFrame?.dispose();
          _retiredFrame = _decodedFrame;
          _decodedFrame = image;
        });
      }
      if (_latestFrame != null && !identical(_latestFrame, bytes)) {
        _scheduleDecode();
      }
    });
  }

  /// Detaches the stream synchronously and closes sockets in the background.
  /// Teardown awaits (cancel/close handshakes) must never gate UI flow — a
  /// wedged or vanished server would otherwise hang every button that stops
  /// the stream, with no timeout able to save fake-async test time.
  void _detachStream() {
    final sub = _frameSub;
    final stream = _frameStream;
    _frameSub = null;
    _frameStream = null;
    if (mounted) {
      setState(() {
        _streaming = false;
        _previewing = false;
      });
    }
    Future(() async {
      try {
        await Future.wait([
          sub?.cancel() ?? Future.value(),
          stream?.disconnect() ?? Future.value(),
        ]).timeout(const Duration(seconds: 3));
      } catch (_) {}
    });
  }

  Future<void> _onDisconnectPressed() async {
    _detachStream();
    if (!mounted) return;
    setState(() {
      _connected = null;
      _markerLog.clear();
      _latestFrame = null;
      _latestHeader = null;
      _retiredFrame?.dispose();
      _retiredFrame = null;
      _decodedFrame?.dispose();
      _decodedFrame = null;
      _endOfStream = false;
      _courtReady = false;
      _courtCorners = 0;
      _calibrationImage = null;
      _calibrationCorners = const [];
      _calibrated = false;
    });
    try {
      await _rest.disconnect();
      _showSnack('Disconnected and frame stream stopped.');
    } on RestException catch (e) {
      _showSnack('Disconnect failed: ${e.message}');
    }
  }

  Future<void> _onDetectCourtPressed() async {
    if (_connected == null) {
      _showSnack('Connect a source first.');
      return;
    }
    _detachStream();
    if (!mounted) return;
    setState(() => _detectingCourt = true);
    try {
      final snapshot = await _rest.fetchSnapshot();
      final result = await _rest.detectCourt();
      if (!mounted) return;
      final points = result.points.isNotEmpty
          ? result.points
              .map((p) => Offset(p.x, p.y))
              .toList()
          : result.corners
              .map((c) => Offset(
                    ((c['center'] as List?)?.first as num?)?.toDouble() ?? 0,
                    ((c['center'] as List?)?.length == 2
                            ? (c['center'] as List)[1] as num?
                            : null)
                        ?.toDouble() ??
                        0,
                  ))
              .toList();
      if (points.length != 4) {
        // Never guess corner positions: without all 4 corners the boundary
        // is meaningless, so send the user back to reposition the camera.
        if (!mounted) return;
        setState(() {
          _courtReady = false;
          _courtCorners = result.corners.length;
          _calibrationImage = null;
          _calibrationCorners = const [];
        });
        await _showIncompleteCourtDialog(points.length);
        return;
      }
      setState(() {
        _courtReady = result.courtReady;
        _courtCorners = result.corners.length;
        _calibrationImage = snapshot;
        _calibrationCorners = points;
        _snapshotWidth = result.width;
        _snapshotHeight = result.height;
      });
      _showSnack('Review the 4 court corners — drag to adjust, then confirm to start the stream.');
    } on RestException catch (e) {
      if (!mounted) return;
      _showSnack('Court detection failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _detectingCourt = false);
    }
  }

  Future<void> _showIncompleteCourtDialog(int found) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Court not fully visible'),
        content: Text(
          'Only $found of 4 court corners were detected. '
          'Reposition the camera so the entire court is in frame, '
          'then try Detect again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back to preview'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _onDetectCourtPressed();
            },
            child: const Text('Retry detect'),
          ),
        ],
      ),
    );
  }

  Future<void> _onConfirmCourtPressed() async {
    if (_connected == null || _calibrationCorners.length != 4) {
      _showSnack('Detect the court and position all 4 corners first.');
      return;
    }
    setState(() => _confirmingCourt = true);
    try {
      await _rest.confirmCourt(_calibrationCorners
          .map((o) => CourtPoint(x: o.dx, y: o.dy))
          .toList());
      if (!mounted) return;
      setState(() => _calibrated = true);
      _startFrameStream();
      _showSnack('Court confirmed — live ball tracking started.');
    } on RestException catch (e) {
      if (!mounted) return;
      _showSnack('Court confirmation failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _confirmingCourt = false);
    }
  }

  Future<void> _onRecalibratePressed() async {
    _detachStream();
    if (!mounted) return;
    setState(() {
      _calibrated = false;
      _markerLog.clear();
      _calibrationImage = null;
      _calibrationCorners = const [];
      _latestFrame = null;
      _latestHeader = null;
    });
    try {
      await _rest.recalibrate();
    } on RestException catch (e) {
      _showSnack('Recalibrate failed: ${e.message}');
      return;
    }
    // Back to raw preview so the camera can be re-aimed before re-detecting.
    _startPreviewStream();
    _showSnack('Back to live preview — press Detect when ready to recalibrate.');
  }

  Future<void> _onResumePreviewPressed() async {
    if (_connected == null) return;
    _detachStream();
    if (!mounted) return;
    setState(() {
      _calibrationImage = null;
      _calibrationCorners = const [];
      _courtReady = false;
      _courtCorners = 0;
    });
    _startPreviewStream();
  }

  void _onBrowsePressed() {
    _pickVideoFile().then((path) {
      if (path != null && mounted) {
        setState(() => _filePathController.text = path);
      }
    });
  }

  Future<String?> _pickVideoFile() async {
    const typeGroup = XTypeGroup(
      label: 'Videos',
      extensions: ['mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      return file?.path;
    } catch (e) {
      _showSnack('File picker failed: $e');
      return null;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _sourceSummary {
    if (_kind == VideoSourceKind.camera) {
      return 'Camera $_cameraIndex';
    }
    final path = _filePathController.text.trim();
    return path.isEmpty ? 'No file selected' : path;
  }

  @override
  Widget build(BuildContext context) {
    final sidecarColor =
        _sidecarConnected ? AppColors.ok : AppColors.danger;
    final sidecarValue = _sidecarConnected ? 'Connected' : 'Disconnected';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_tennis, size: 24, color: AppColors.courtGreenBright),
            const SizedBox(width: 10),
            const Flexible(
              child: Text('Pickleball Court Analysis', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _StatusBadge(
              label: 'Sidecar',
              value: sidecarValue,
              color: sidecarColor,
            ),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SourcePanel(
            kind: _kind,
            cameraIndex: _cameraIndex,
            cameraList: _cameraList,
            samples: _samples,
            fileController: _filePathController,
            connecting: _connecting,
            sidecarConnected: _sidecarConnected,
            connected: _connected,
            onKindChanged: _onKindChanged,
            onCameraChanged: _onCameraChanged,
            onConnectPressed: _onConnectPressed,
            onDisconnectPressed: _onDisconnectPressed,
            onBrowsePressed: _onBrowsePressed,
            onSampleSelected: (path) {
              setState(() => _filePathController.text = path);
            },
            onDetectCourtPressed: _onDetectCourtPressed,
            detectingCourt: _detectingCourt,
            courtReady: _courtReady,
            courtCorners: _courtCorners,
            calibrationReady: _calibrationCorners.length == 4 &&
                _calibrationImage != null &&
                !_calibrated,
            confirmingCourt: _confirmingCourt,
            calibrated: _calibrated,
            streaming: _streaming,
            onConfirmCourtPressed: _onConfirmCourtPressed,
            onRecalibratePressed: _onRecalibratePressed,
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _calibrationImage != null &&
                          !_streaming &&
                          !_previewing
                      ? _CalibrationViewport(
                          imageBytes: _calibrationImage!,
                          corners: _calibrationCorners,
                          imageWidth: _snapshotWidth,
                          imageHeight: _snapshotHeight,
                          calibrated: _calibrated,
                          onCornersChanged: (corners) {
                            setState(() => _calibrationCorners = corners);
                          },
                          onResumePreview: _onResumePreviewPressed,
                        )
                      : _FeedViewport(
                          sourceSummary: _sourceSummary,
                          connected: _connected,
                          frameImage: _decodedFrame,
                          header: _latestHeader,
                          endOfStream: _endOfStream,
                          feedLabel: _previewing ? 'Preview' : 'Feed',
                          preview: _previewing,
                        ),
                ),
                Divider(height: 1, thickness: 1, color: AppColors.border),
                _Timeline(
                  header: _latestHeader,
                  markers: _markerLog.markers,
                ),
                Divider(height: 1, thickness: 1, color: AppColors.border),
                _StatusBar(
                  sidecarConnected: _sidecarConnected,
                  sourceConnected: _connected != null,
                  phase: _connected == null
                      ? 'IDLE'
                      : (_calibrated ? 'LIVE_TRACKING' : 'SETUP'),
                  courtLabel: _calibrated
                      ? 'Calibrated ✓'
                      : (_calibrationCorners.length == 4
                          ? 'Review corners'
                          : 'Not calibrated'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourcePanel extends StatelessWidget {
  const _SourcePanel({
    required this.kind,
    required this.cameraIndex,
    required this.cameraList,
    required this.samples,
    required this.fileController,
    required this.connecting,
    required this.sidecarConnected,
    required this.connected,
    required this.onKindChanged,
    required this.onCameraChanged,
    required this.onConnectPressed,
    required this.onDisconnectPressed,
    required this.onBrowsePressed,
    required this.onSampleSelected,
    required this.onDetectCourtPressed,
    required this.detectingCourt,
    required this.courtReady,
    required this.courtCorners,
    required this.calibrationReady,
    required this.confirmingCourt,
    required this.calibrated,
    required this.streaming,
    required this.onConfirmCourtPressed,
    required this.onRecalibratePressed,
  });

  final VideoSourceKind kind;
  final int cameraIndex;
  final List<int> cameraList;
  final List<String> samples;
  final TextEditingController fileController;
  final bool connecting;
  final bool sidecarConnected;
  final VideoConnectResult? connected;
  final ValueChanged<VideoSourceKind> onKindChanged;
  final ValueChanged<int?> onCameraChanged;
  final VoidCallback onConnectPressed;
  final VoidCallback onDisconnectPressed;
  final VoidCallback onBrowsePressed;
  final ValueChanged<String> onSampleSelected;
  final VoidCallback onDetectCourtPressed;
  final bool detectingCourt;
  final bool courtReady;
  final int courtCorners;
  final bool calibrationReady;
  final bool confirmingCourt;
  final bool calibrated;
  final bool streaming;
  final VoidCallback onConfirmCourtPressed;
  final VoidCallback onRecalibratePressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      color: AppColors.surfaceAlt,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Video Source', style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            )),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Camera'),
                  avatar: const Icon(Icons.videocam_outlined, size: 18),
                  selected: kind == VideoSourceKind.camera,
                  onSelected: (_) => onKindChanged(VideoSourceKind.camera),
                ),
                ChoiceChip(
                  label: const Text('Video File'),
                  avatar: const Icon(Icons.movie_outlined, size: 18),
                  selected: kind == VideoSourceKind.file,
                  onSelected: (_) => onKindChanged(VideoSourceKind.file),
                ),
              ],
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: kind == VideoSourceKind.camera
                  ? _CameraSourceFields(
                      cameraIndex: cameraIndex,
                      cameraList: cameraList,
                      onCameraChanged: onCameraChanged,
                    )
                  : Column(
                      key: const ValueKey('file-fields'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _FileSourceFields(
                          controller: fileController,
                          onBrowsePressed: onBrowsePressed,
                        ),
                        if (samples.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Text('Sample videos', style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          )),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: samples.map((path) {
                              final name = path.split('/').last;
                              return ActionChip(
                                avatar: const Icon(Icons.movie_outlined, size: 16),
                                label: Text(name),
                                onPressed: () => onSampleSelected(path),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: connecting ? null : onConnectPressed,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.courtGreenBright,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: Icon(connecting ? Icons.hourglass_top : Icons.play_arrow),
              label: Text(connecting ? 'Connecting…' : 'Connect Source'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: (connecting || connected == null) ? null : onDisconnectPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Disconnect'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed:
                      (connecting || detectingCourt || connected == null || streaming)
                          ? null
                          : onDetectCourtPressed,
              style: FilledButton.styleFrom(
                foregroundColor: AppColors.courtGreenBright,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: Icon(detectingCourt ? Icons.hourglass_top : Icons.crop_free),
              label: Text(
                detectingCourt
                    ? 'Detecting…'
                    : (courtReady ? 'Re-detect Court ($courtCorners corners)' : '1 · Detect Court'),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: (!calibrationReady || confirmingCourt)
                  ? null
                  : onConfirmCourtPressed,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.courtGreenBright,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: Icon(confirmingCourt ? Icons.hourglass_top : Icons.check_circle_outline),
              label: Text(confirmingCourt
                  ? 'Confirming…'
                  : (calibrated ? 'Court Confirmed ✓' : '2 · Confirm Court & Start Stream')),
            ),
            if (streaming) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: onRecalibratePressed,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warn,
                  side: const BorderSide(color: AppColors.warn),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.tune),
                label: const Text('Recalibrate Court'),
              ),
            ],
            if (!sidecarConnected) ...[
              const SizedBox(height: 10),
              Text(
                'Waiting for sidecar…',
                style: TextStyle(fontSize: 12, color: AppColors.warn.withValues(alpha: 0.9)),
              ),
            ],
            const SizedBox(height: 24),
            const Text('Connected Source', style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            )),
            const SizedBox(height: 8),
            _SourceSummaryCard(
              kind: kind,
              cameraIndex: cameraIndex,
              path: fileController.text.trim(),
              connected: connected,
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraSourceFields extends StatelessWidget {
  const _CameraSourceFields({
    required this.cameraIndex,
    required this.cameraList,
    required this.onCameraChanged,
  });

  final int cameraIndex;
  final List<int> cameraList;
  final ValueChanged<int?> onCameraChanged;

  @override
  Widget build(BuildContext context) {
    final items = cameraList.isNotEmpty
        ? cameraList
        : List.generate(9, (i) => i);
    final value = items.contains(cameraIndex) ? cameraIndex : null;
    return DropdownButtonFormField<int>(
      key: ValueKey('camera-field-${items.join(',')}-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Camera device',
        hintText: cameraList.isEmpty ? 'No cameras detected' : null,
      ),
      items: items
          .map((i) => DropdownMenuItem(value: i, child: Text('Camera $i')))
          .toList(),
      onChanged: onCameraChanged,
    );
  }
}

class _FileSourceFields extends StatelessWidget {
  const _FileSourceFields({
    required this.controller,
    required this.onBrowsePressed,
  });

  final TextEditingController controller;
  final VoidCallback onBrowsePressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('file-field'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Video file path',
              hintText: '/path/to/video.mp4',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton.icon(
            onPressed: onBrowsePressed,
            icon: const Icon(Icons.folder_open),
            label: const Text('Browse'),
          ),
        ),
      ],
    );
  }
}

class _SourceSummaryCard extends StatelessWidget {
  const _SourceSummaryCard({
    required this.kind,
    required this.cameraIndex,
    required this.path,
    required this.connected,
  });

  final VideoSourceKind kind;
  final int cameraIndex;
  final String path;
  final VideoConnectResult? connected;

  @override
  Widget build(BuildContext context) {
    final summary = connected?.label ??
        (kind == VideoSourceKind.camera
            ? 'Camera $cameraIndex'
            : (path.isEmpty ? 'No file selected' : path));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: connected != null ? AppColors.courtGreenBright : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            connected != null ? Icons.check_circle : (kind == VideoSourceKind.camera ? Icons.videocam : Icons.movie),
            size: 18,
            color: connected != null ? AppColors.ok : AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalibrationViewport extends StatelessWidget {
  const _CalibrationViewport({
    required this.imageBytes,
    required this.corners,
    required this.imageWidth,
    required this.imageHeight,
    required this.calibrated,
    required this.onCornersChanged,
    required this.onResumePreview,
  });

  final Uint8List imageBytes;
  final List<Offset> corners;
  final int? imageWidth;
  final int? imageHeight;
  final bool calibrated;
  final ValueChanged<List<Offset>> onCornersChanged;
  final VoidCallback onResumePreview;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CourtCalibrationOverlay(
            key: ValueKey('calibration-${corners.join()}'),
            initialCorners: corners,
            imageBytes: imageBytes,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            onChanged: onCornersChanged,
          ),
          Positioned(
            top: 12,
            left: 12,
            child: _StatusBadge(
              label: 'Setup',
              value: calibrated
                  ? 'Court confirmed'
                  : 'Drag corners 1–4 to align, then confirm',
              color: calibrated ? AppColors.ok : AppColors.warn,
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: OutlinedButton.icon(
              onPressed: onResumePreview,
              style: OutlinedButton.styleFrom(
                backgroundColor: AppColors.surface,
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.border),
              ),
              icon: const Icon(Icons.live_tv, size: 16),
              label: const Text('Resume preview'),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedViewport extends StatelessWidget {
  const _FeedViewport({
    required this.sourceSummary,
    required this.connected,
    required this.frameImage,
    required this.header,
    required this.endOfStream,
    this.feedLabel = 'Feed',
    this.preview = false,
  });

  final String sourceSummary;
  final VideoConnectResult? connected;
  final ui.Image? frameImage;
  final FrameHeader? header;
  final bool endOfStream;
  final String feedLabel;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final isConnected = connected != null;
    final hasFrame = frameImage != null;

    if (!hasFrame) {
      return Container(
        color: AppColors.surface,
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isConnected ? AppColors.courtGreenBright : AppColors.border,
                      ),
                    ),
                    child: Icon(
                      isConnected ? Icons.hourglass_top : Icons.videocam_off_outlined,
                      size: 40,
                      color: isConnected ? AppColors.ok : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isConnected ? 'Starting preview…' : 'No feed',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isConnected
                        ? 'Receiving analysis stream from sidecar'
                        : sourceSummary.isEmpty
                            ? 'Select a source and connect to preview'
                            : 'Preview for "$sourceSummary" will appear here once connected',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            _viewportBadge(isConnected),
          ],
        ),
      );
    }

    return Container(
      color: AppColors.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Server already draws detection boxes onto the JPEG. The frame is
          // decoded once per received frame in _startFrameStream and blitted
          // here, so the display always tracks the frame counter.
          Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: RawImage(image: frameImage),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: _StatusBadge(
              label: feedLabel,
              value: endOfStream
                  ? 'End'
                  : (preview
                      ? 'Live · no analysis · Frame ${header?.frameIndex ?? '-'}'
                      : 'Frame ${header?.frameIndex ?? '-'} · ${_fmtTime(header?.timestamp)}'),
              color: endOfStream
                  ? AppColors.danger
                  : (preview ? AppColors.warn : AppColors.ok),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewportBadge(bool isConnected) {
    return Positioned(
      top: 12,
      left: 12,
      child: _StatusBadge(
        label: 'Feed',
        value: isConnected ? 'Connected' : 'Offline',
        color: isConnected ? AppColors.ok : AppColors.textSecondary,
      ),
    );
  }

  static String _fmtTime(double? t) {
    if (t == null) return '00:00';
    final total = t.round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.header, required this.markers});

  final FrameHeader? header;
  final List<TimelineMarker> markers;

  static const _totalSeconds = 60;

  String get _timeText {
    final t = header?.timestamp;
    if (t == null) return '00:00';
    final total = t.round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final now = header?.timestamp ?? 0.0;
    // Continuous compacting scale: the strip spans everything seen so far
    // and older markers squeeze left as time grows — nothing ever resets.
    var span = 60.0;
    for (final m in markers) {
      if (m.timestamp > span) span = m.timestamp;
    }
    if (now > span) span = now;
    final bounces = markers.where((m) => m.type == MarkerType.bounce).length;
    final exits = markers.where((m) => m.type == MarkerType.exit).length;
    final summary = markers.isEmpty
        ? 'No events yet'
        : '$bounces bounce · $exits exit';
    return Container(
      color: AppColors.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.timeline, size: 16, color: AppColors.textSecondary.withValues(alpha: 0.8)),
              const SizedBox(width: 8),
              const Text('Timeline', style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              )),
              const SizedBox(width: 12),
              Text(_timeText, style: TextStyle(fontSize: 12, color: AppColors.textSecondary.withValues(alpha: 0.8))),
              const SizedBox(width: 12),
              _MarkerLegend(
                color: AppColors.warn,
                label: 'bounce',
              ),
              const SizedBox(width: 8),
              _MarkerLegend(
                color: AppColors.danger,
                label: 'exit',
              ),
              const Spacer(),
              Text(
                summary,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary.withValues(alpha: 0.8)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 24,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Row(
                      children: List.generate(_totalSeconds, (s) {
                        final isMinuteMark = s % 15 == 0;
                        final isPast = header != null;
                        return Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: isMinuteMark ? 8 : 3,
                              width: 1,
                              color: isPast
                                  ? AppColors.courtGreenBright
                                  : (isMinuteMark
                                      ? AppColors.textSecondary.withValues(alpha: 0.5)
                                      : AppColors.border),
                            ),
                          ),
                        );
                      }),
                    ),
                    for (final marker in markers)
                      Positioned(
                        left: (marker.timestamp / span) *
                                constraints.maxWidth -
                            1,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 2,
                          color: marker.type == MarkerType.bounce
                              ? AppColors.warn
                              : AppColors.danger,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkerLegend extends StatelessWidget {
  const _MarkerLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 2, height: 12, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary.withValues(alpha: 0.8)),
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.sidecarConnected,
    required this.sourceConnected,
    this.phase = 'SETUP',
    this.courtLabel = 'Not calibrated',
  });

  final bool sidecarConnected;
  final bool sourceConnected;
  final String phase;
  final String courtLabel;

  @override
  Widget build(BuildContext context) {
    final note = !sidecarConnected
        ? 'Waiting for sidecar connection…'
        : (sourceConnected ? 'Source connected' : 'Sidecar ready — connect a source');
    return Container(
      color: AppColors.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusBadgeText(label: 'Phase', value: phase),
                const SizedBox(width: 24),
                Flexible(
                  child: _StatusBadgeText(label: 'Court', value: courtLabel),
                ),
              ],
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            '$label · $value',
            style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _StatusBadgeText extends StatelessWidget {
  const _StatusBadgeText({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
    );
  }
}