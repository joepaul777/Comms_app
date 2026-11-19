import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'push_api.dart';

class ReleaseInfo {
  final String version;
  final int build;
  final String url;
  final String notes;
  ReleaseInfo(this.version, this.build, this.url, this.notes);
}

/// Checks for a newer Comms build and installs it.
class UpdateService {
  UpdateService._();

  static Future<PackageInfo> current() => PackageInfo.fromPlatform();

  /// The newer release, or null if this phone is up to date (or the check failed).
  static Future<ReleaseInfo?> newerRelease() async {
    // The web version is always the newest; there is nothing to install.
    if (kIsWeb) return null;
    final data = await PushApi.latestRelease();
    if (data == null) return null;
    final latest = ReleaseInfo(
      data['version'] as String? ?? '',
      (data['build'] as num?)?.toInt() ?? 0,
      data['url'] as String? ?? '',
      data['notes'] as String? ?? '',
    );
    final installed = int.tryParse((await current()).buildNumber) ?? 0;
    return latest.build > installed && latest.url.isNotEmpty ? latest : null;
  }

  /// Downloads the APK and hands it to Android's installer.
  /// Falls back to opening the download in the browser if that is not possible.
  static Future<void> install(ReleaseInfo release, {void Function(double)? onProgress}) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/comms-${release.version}.apk');
      await Dio().download(release.url, file.path, onReceiveProgress: (got, total) {
        if (total > 0) onProgress?.call(got / total);
      });
      final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      if (result.type == ResultType.done) return;
      debugPrint('installer did not open: ${result.message}');
    } catch (e) {
      debugPrint('update download failed: $e');
    }
    await launchUrl(Uri.parse(release.url), mode: LaunchMode.externalApplication);
  }
}
