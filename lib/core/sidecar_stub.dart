/// Web-safe no-op implementation of [SidecarManager].
///
/// Browsers cannot spawn subprocesses, so on web builds this stub is imported
/// instead of the real `dart:io` implementation in [sidecar_manager.dart].
class SidecarManager {
  SidecarManager({void Function(String line)? onLog, void Function(int exitCode)? onExit});

  bool get isRunning => false;

  Future<void> launch() async {}

  Future<void> shutdown() async {}
}