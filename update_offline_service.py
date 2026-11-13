import sys

file_path = r'C:\JOEPAUL\Comms\lib\services\offline_chat_service.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Add flutter_local_notifications import
if "flutter_local_notifications" not in content:
    content = "import 'package:flutter_local_notifications/flutter_local_notifications.dart';\n" + content

# Add isChatScreenOpen flag
if "bool isChatScreenOpen = false;" not in content:
    content = content.replace(
        "List<MessageModel> messages = [];", 
        "List<MessageModel> messages = [];\n  bool isChatScreenOpen = false;"
    )

# Add local notifications plugin instance
if "final FlutterLocalNotificationsPlugin _notificationsPlugin =" not in content:
    content = content.replace(
        "class OfflineChatService extends ChangeNotifier {",
        "class OfflineChatService extends ChangeNotifier {\n  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();"
    )

# Modify _onPayloadReceived to show notification if not open
old_payload = """  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      try {
        final jsonStr = utf8.decode(payload.bytes!);
        final map = jsonDecode(jsonStr);
        final message = MessageModel.fromMap(map);
        messages.insert(0, message); // Insert at 0 because ListView is reverse
        notifyListeners();
      } catch (e) {
        print("Failed to decode offline message: $e");
      }
    }
  }"""

new_payload = """  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      try {
        final jsonStr = utf8.decode(payload.bytes!);
        final map = jsonDecode(jsonStr);
        final message = MessageModel.fromMap(map);
        messages.insert(0, message); // Insert at 0 because ListView is reverse
        notifyListeners();
        
        if (!isChatScreenOpen) {
          _showNotification(message.senderName, message.text);
        }
      } catch (e) {
        print("Failed to decode offline message: $e");
      }
    }
  }
  
  Future<void> _showNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'offline_channel_id',
      'Offline Messages',
      importance: Importance.max,
      priority: Priority.high,
    );
    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);
    
    await _notificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      platformDetails,
    );
  }"""

content = content.replace(old_payload, new_payload)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated offline_chat_service.dart successfully!")
