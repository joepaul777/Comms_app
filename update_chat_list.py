import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_list_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

if "import '../../services/offline_chat_service.dart';" not in content:
    content = "import '../../services/offline_chat_service.dart';\n" + content

old_state = """class _ChatListScreenState extends State<ChatListScreen> {
  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();

  @override
  Widget build(BuildContext context) {"""

new_state = """class _ChatListScreenState extends State<ChatListScreen> {
  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();

  @override
  void initState() {
    super.initState();
    _startPassiveOfflineMode();
  }

  Future<void> _startPassiveOfflineMode() async {
    final offlineService = OfflineChatService();
    final currentUid = _authService.currentUserId;
    if (currentUid != null) {
      final user = await _userService.getUser(currentUid);
      if (user != null) {
        final hasPermissions = await offlineService.requestPermissions();
        if (hasPermissions && !offlineService.isAdvertising) {
          await offlineService.startAdvertising(user.name);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {"""

content = content.replace(old_state, new_state)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated chat_list_screen.dart successfully!")
