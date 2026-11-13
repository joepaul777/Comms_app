import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Fix 1: _MessageBubble text color
old_text = "color: isMine ? AppColors.textDark : AppColors.text,"
new_text = "color: isMine ? Colors.white : AppColors.text,"
content = content.replace(old_text, new_text)

# Fix 2: Redesign voice note and send buttons in _buildInputBar
# Find the AnimatedContainer for the mic/send button
old_button = """                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: _isRecording ? 52 : 44,
                  height: _isRecording ? 52 : 44,
                  margin: EdgeInsets.only(bottom: _isRecording ? 0 : 2),
                  decoration: BoxDecoration(
                    color: _isRecording ? AppColors.error : Colors.transparent,
                    gradient: _isRecording ? null : AppColors.primaryGradient,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (_isRecording ? AppColors.error : AppColors.primary).withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    _isTextFieldEmpty ? Icons.mic_rounded : Icons.send_rounded,
                    color: _isRecording ? Colors.white : AppColors.textDark,
                    size: _isRecording ? 24 : 20,
                  ),
                ),"""

new_button = """                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: _isRecording ? 52 : 44,
                  height: _isRecording ? 52 : 44,
                  margin: EdgeInsets.only(bottom: _isRecording ? 0 : 2),
                  decoration: BoxDecoration(
                    color: _isRecording ? AppColors.error : AppColors.primary.withOpacity(0.2),
                    shape: BoxShape.circle,
                    border: Border.all(color: _isRecording ? Colors.transparent : AppColors.primary.withOpacity(0.5)),
                  ),
                  child: Icon(
                    _isTextFieldEmpty ? Icons.mic_rounded : Icons.send_rounded,
                    color: _isRecording ? Colors.white : AppColors.primary,
                    size: _isRecording ? 24 : 20,
                  ),
                ),"""

content = content.replace(old_button, new_button)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Replaced UI in chat_screen.dart successfully!")
