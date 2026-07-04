import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateService {
  // TODO: Replace this URL with the actual URL where your version.json is hosted
  static const String updateCheckUrl = 'https://example.com/version.json';

  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final dio = Dio();
      final response = await dio.get(
        updateCheckUrl,
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200) {
        // Expected JSON format:
        // {
        //   "latest_version": "1.0.1",
        //   "download_url": "https://example.com/comms_latest.apk",
        //   "release_notes": "Bug fixes and improvements"
        // }
        
        final data = response.data;
        if (data is String) {
          // In case the response is not auto-parsed to JSON
          final parsed = jsonDecode(data);
          _compareAndPrompt(context, parsed);
        } else {
          _compareAndPrompt(context, data);
        }
      }
    } catch (e) {
      debugPrint('Error checking for updates: $e');
    }
  }

  static Future<void> _compareAndPrompt(BuildContext context, Map<String, dynamic> data) async {
    final String latestVersion = data['latest_version'];
    final String downloadUrl = data['download_url'];
    final String? releaseNotes = data['release_notes'];

    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    final String currentVersion = packageInfo.version;

    if (_isNewerVersion(currentVersion, latestVersion)) {
      if (context.mounted) {
        _showUpdateDialog(context, latestVersion, downloadUrl, releaseNotes);
      }
    }
  }

  static bool _isNewerVersion(String current, String latest) {
    final currentParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final latestParts = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (int i = 0; i < latestParts.length; i++) {
      final latestPart = latestParts[i];
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      
      if (latestPart > currentPart) return true;
      if (latestPart < currentPart) return false;
    }
    return false;
  }

  static void _showUpdateDialog(
    BuildContext context, 
    String latestVersion, 
    String downloadUrl, 
    String? releaseNotes
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF171717),
          title: const Text(
            'Update Available',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A new version ($latestVersion) is available! Please update to get the latest features and bug fixes.',
                style: const TextStyle(color: Colors.white70),
              ),
              if (releaseNotes != null && releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'What\'s new:',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  releaseNotes,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Later', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFACC15),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                final url = Uri.parse(downloadUrl);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
                if (context.mounted) {
                  Navigator.pop(context);
                }
              },
              child: const Text('Update Now', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }
}
