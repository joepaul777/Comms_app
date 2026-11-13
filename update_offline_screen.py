import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\offline_chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

old_init = """  void initState() {
    super.initState();
    _offlineService.addListener(_onServiceUpdate);
  }"""

new_init = """  void initState() {
    super.initState();
    _offlineService.isChatScreenOpen = true;
    _offlineService.addListener(_onServiceUpdate);
  }"""

content = content.replace(old_init, new_init)

old_dispose = """  void dispose() {
    _offlineService.removeListener(_onServiceUpdate);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }"""

new_dispose = """  void dispose() {
    _offlineService.isChatScreenOpen = false;
    _offlineService.removeListener(_onServiceUpdate);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }"""

content = content.replace(old_dispose, new_dispose)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated offline_chat_screen.dart successfully!")
