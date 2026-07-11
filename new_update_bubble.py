import sys
import re

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Imports
imports = """import '../../widgets/media_message_widget.dart';
import '../../widgets/audio_message_widget.dart';
"""
if "import '../../widgets/media_message_widget.dart';" not in content:
    content = re.sub(r"(import '../../widgets/full_screen_image_viewer\.dart';)", r"\1\n" + imports, content)

# 2. Add _buildMessageContent ONLY to _MessageBubble
method_to_add = """  Widget _buildMessageContent(BuildContext context) {
    if (message.type == MessageType.image || message.type == MessageType.video || message.type == MessageType.gif) {
      return MediaMessageWidget(message: message, isMine: isMine);
    } else if (message.type == MessageType.audio) {
      return AudioMessageWidget(message: message, isMine: isMine);
    }
    
    return Text(
      message.text,
      style: GoogleFonts.inter(
        fontSize: 14,
        color: isMine ? AppColors.textDark : AppColors.text,
        height: 1.4,
      ),
    );
  }

  @override"""

# We must find the EXACT `  @override\n  Widget build(BuildContext context)` inside `_MessageBubble`
bubble_start = content.find("class _MessageBubble extends StatelessWidget {")
if bubble_start != -1:
    bubble_end = content.find("class _SystemMessage", bubble_start)
    bubble_content = content[bubble_start:bubble_end]
    
    # Replace the build method
    new_bubble_content = re.sub(r"  @override\s*Widget build\(BuildContext context\)", method_to_add + "\n  Widget build(BuildContext context)", bubble_content, count=1)
    
    # Replace the text widget inside the bubble
    text_pattern = r"""                Text\(
                  message\.text,
                  style: GoogleFonts\.inter\(
                    fontSize: 14,
                    color: AppColors\.text,
                    height: 1\.4,
                  \),
                \),"""
    new_bubble_content = re.sub(text_pattern, "                _buildMessageContent(context),", new_bubble_content)
    
    content = content[:bubble_start] + new_bubble_content + content[bubble_end:]

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated chat_screen.dart bubble successfully!")
