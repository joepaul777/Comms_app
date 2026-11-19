/// Notifications: pushes and the notification shade on a phone, the browser's own
/// notifications on the web.
library;

export 'notification_service_mobile.dart' if (dart.library.js_interop) 'notification_service_web.dart';
