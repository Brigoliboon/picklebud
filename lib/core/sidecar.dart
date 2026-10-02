/// Conditional sidecar entrypoint.
///
/// [sidecar_manager.dart] has the real `dart:io` subprocess implementation
/// used on desktop; [sidecar_stub.dart] is imported on web where subprocess
/// spawning is unavailable. Conflicting named constructors are avoided by
/// keeping the same interface in both files.
library;

export 'sidecar_manager.dart'
    if (dart.library.js_interop) 'sidecar_stub.dart';