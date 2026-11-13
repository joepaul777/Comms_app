import sys

file_path = r'C:\JOEPAUL\Comms\lib\services\media_service.dart'

content = """import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';

class MediaService {
  static final MediaService _instance = MediaService._internal();
  factory MediaService() => _instance;
  MediaService._internal();

  final Dio _dio = Dio();

  /// Uploads a file to tmpfiles.org and returns the download URL.
  Future<String?> uploadMedia({
    required File file,
    required String messageId,
    required String fileName,
  }) async {
    try {
      FormData formData = FormData.fromMap({
        "file": await MultipartFile.fromFile(file.path, filename: fileName),
      });

      final response = await _dio.post(
        'https://tmpfiles.org/api/v1/upload',
        data: formData,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data != null && data['status'] == 'success') {
          final url = data['data']['url'] as String;
          // tmpfiles.org returns https://tmpfiles.org/123456/file.ext
          // To download directly, we must change it to https://tmpfiles.org/dl/123456/file.ext
          return url.replaceFirst('tmpfiles.org/', 'tmpfiles.org/dl/');
        }
      }
      return null;
    } catch (e) {
      print('Error uploading media: $e');
      return null;
    }
  }

  /// Downloads a file from the URL to the local device storage.
  Future<String?> downloadMedia({
    required String url,
    required String fileName,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/media/$fileName';
      
      // Ensure directory exists
      final mediaDir = Directory('${dir.path}/media');
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      await _dio.download(url, savePath);
      return savePath;
    } catch (e) {
      print('Error downloading media: $e');
      return null;
    }
  }

  /// Deletes the local file from the device.
  Future<void> deleteLocalFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Error deleting local file: $e');
    }
  }
}
"""

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Replaced media_service.dart successfully!")
