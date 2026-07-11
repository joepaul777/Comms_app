import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';

class MediaService {
  static final MediaService _instance = MediaService._internal();
  factory MediaService() => _instance;
  MediaService._internal();

  final FirebaseStorage _storage = FirebaseStorage.instance;
  final Dio _dio = Dio();

  /// Uploads a file to a temporary bucket in Firebase Storage and returns the download URL.
  Future<String?> uploadMedia({
    required File file,
    required String messageId,
    required String fileName,
  }) async {
    try {
      final ref = _storage.ref().child('temp_media/$messageId/$fileName');
      final uploadTask = await ref.putFile(file);
      final downloadUrl = await uploadTask.ref.getDownloadURL();
      return downloadUrl;
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

  /// Immediately deletes the file from the cloud to ensure no permanent storage.
  Future<void> deleteMediaFromCloud(String messageId, String fileName) async {
    try {
      final ref = _storage.ref().child('temp_media/$messageId/$fileName');
      await ref.delete();
    } catch (e) {
      print('Error deleting media from cloud: $e');
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
