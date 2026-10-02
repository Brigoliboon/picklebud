import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball/core/frame_stream_client.dart';
import 'package:pickleball/core/rest_client.dart';

void main() {
  test(
    'parse real WS frames from sidecar',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // Generous timeout: model load + inference happen on first requests.
      final rest = RestClient(timeout: const Duration(seconds: 60));
      StreamSubscription<AnalyzedFrame>? sub;
      final client = FrameStreamClient();
      try {
        // First connect a real video source so /live/frames has something.
        await rest.connectFile(
            '/home/devxploit/Projects/client/desktop/pickleball/server/sample.mp4');
        // Live stream is gated on court calibration: confirm corners first.
        final detected = await rest.detectCourt();
        final points = detected.points.isNotEmpty
            ? detected.points
            : const [
                CourtPoint(x: 10, y: 10),
                CourtPoint(x: 200, y: 10),
                CourtPoint(x: 200, y: 200),
                CourtPoint(x: 10, y: 200),
              ];
        await rest.confirmCourt(points.sublist(0, 4).toList());

        final frames = <AnalyzedFrame>[];
        sub = client.connect().listen(frames.add);
        await Future.delayed(const Duration(seconds: 6));

        expect(frames.length, greaterThan(0),
            reason: 'sidecar must stream frames');
        final f = frames.first;
        expect(f.header.type, 'frame');
        expect(f.jpegBytes.length, greaterThan(1000));
        expect(f.header.width, greaterThan(0));
        expect(f.header.height, greaterThan(0));
      } finally {
        // Always release the stream so the sidecar stops inference promptly.
        await sub?.cancel();
        await client.disconnect().timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );
        await rest.disconnect().timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );
        rest.close();
      }
    },
  );
}
