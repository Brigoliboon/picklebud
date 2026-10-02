import 'dart:async';
import 'dart:io';

/// Launches the bundled Python sidecar as a subprocess on desktop platforms.
///
/// Web builds have no subprocess support; [sidecar.dart] conditionally imports
/// [sidecar_stub.dart] instead, which never launches anything.
class SidecarManager {
  SidecarManager({this.onLog, this.onExit});

  final void Function(String line)? onLog;
  final void Function(int exitCode)? onExit;

  Process? _process;
  bool _started = false;

  bool get isRunning => _started;

  /// Starts the sidecar if it isn't already running, waiting briefly for it to
  /// accept connections. Returns immediately on platforms without subprocess
  /// support. Safe to call repeatedly — reconnection is handled by the caller.
  Future<void> launch() async {
    if (_started) return;

    final executable = await _resolveExecutable();
    if (executable == null) return;

    final command = <String>[
      executable,
      '-m',
      'uvicorn',
      'main:app',
      '--host',
      '127.0.0.1',
      '--port',
      '8790',
    ];

    _process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: serverDirectory.path,
      runInShell: Platform.isWindows,
    );
    _started = true;

    _process!.stdout.transform(systemEncoding.decoder).listen(
          onLog ?? (_) {},
          onError: (Object _) {},
        );
    _process!.stderr.transform(systemEncoding.decoder).listen(
          onLog ?? (_) {},
          onError: (Object _) {},
        );
    unawaited(_process!.exitCode.then((code) {
      _started = false;
      onExit?.call(code);
    }));
  }

  Future<void> shutdown() async {
    final process = _process;
    if (process == null) return;
    process.kill();
    _process = null;
    _started = false;
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  Future<String?> _resolveExecutable() async {
    final python = File('${serverDirectory.path}/.venv/bin/python');
    if (python.existsSync()) return python.path;

    final pythonWin = File('${serverDirectory.path}/.venv/Scripts/python.exe');
    if (pythonWin.existsSync()) return pythonWin.path;

    return null;
  }

  Directory get serverDirectory {
    // Prod: sidecar is bundled next to the app binary — locate via the
    // executable directory first, then fall back to the dev tree where the
    // server/ folder sits two levels above the Flutter project root.
    final possibleRoots = <String>[
      if (Platform.resolvedExecutable.isNotEmpty)
        File(Platform.resolvedExecutable).parent.parent.path,
      '${Directory.current.path}/../..',
    ];
    for (final root in possibleRoots) {
      final server = Directory('$root/server');
      if (server.existsSync()) return server;
    }
    return Directory('${Directory.current.path}/../..');
  }
}