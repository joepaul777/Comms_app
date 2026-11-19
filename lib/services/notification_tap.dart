/// What happened when a notification was tapped.
class NotificationTap {
  final String type; // chat, call, calls
  final String id;
  final String action; // '', answer, decline
  NotificationTap(this.type, this.id, this.action);
}
