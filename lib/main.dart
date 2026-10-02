import 'package:flutter/material.dart';

import 'core/rest_client.dart';
import 'core/sidecar.dart';
import 'features/video_feed/video_feed_page.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const PickleballApp());
}

class PickleballApp extends StatelessWidget {
  const PickleballApp({super.key, this.restClient, this.sidecarManager});

  final RestClient? restClient;
  final SidecarManager? sidecarManager;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pickleball Court Analysis',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: VideoFeedPage(
        restClient: restClient,
        sidecarManager: sidecarManager,
      ),
    );
  }
}