import sys

file_path = r'C:\JOEPAUL\Comms\lib\services\media_service.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

dummy_method = """  /// Deletes the file from the cloud (if supported).
  Future<void> deleteMediaFromCloud(String messageId, String fileName) async {
    // tmpfiles.org handles auto-deletion, so this is a no-op for now.
  }
}"""

content = content.replace("}", dummy_method)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Added deleteMediaFromCloud back to MediaService.")
