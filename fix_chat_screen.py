import sys
import re

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Fix the extra parentheses in _MessageBubble
content = content.replace("      ),\n    )));\n  }\n}\n\nclass _SystemMessage", "      ),\n    );\n  }\n}\n\nclass _SystemMessage")

# We want to keep _buildMessageContent in _MessageBubble, but remove it from the others.
# Let's find _MessageBubble class bounds
bubble_idx = content.find("class _MessageBubble extends StatelessWidget {")
sys_idx = content.find("class _SystemMessage extends StatelessWidget {")

if bubble_idx != -1 and sys_idx != -1:
    before_sys = content[:sys_idx]
    after_sys = content[sys_idx:]
    
    # Remove _buildMessageContent from after_sys
    pattern = r"  Widget _buildMessageContent\(BuildContext context\) \{.*?\n  \}\n\n"
    after_sys = re.sub(pattern, "", after_sys, flags=re.DOTALL)
    
    content = before_sys + after_sys

# Fix the missing parenthesis from update_design in _buildInputBar if we messed it up
# update_design.py tried to add `)));` to _buildInputBar. It failed and added it to _MessageBubble.
# Let's make sure _buildInputBar is correct.
# In _buildInputBar, we changed:
# return Container( -> return ClipRect(child: BackdropFilter(filter: ..., child: Container(
# But we didn't close them properly.
# The end of _buildInputBar looks like:
#           ),
#         ],
#       ),
#     );
#   }
# Let's find _buildInputBar
input_idx = content.find("Widget _buildInputBar() {")
swipe_idx = content.find("class _SwipeableMessageBubble extends StatefulWidget {")
if input_idx != -1 and swipe_idx != -1:
    input_code = content[input_idx:swipe_idx]
    # It probably ends with `    );\n  }\n\n`
    # We need to change it to `    )));\n  }\n\n`
    if not input_code.rstrip().endswith(")));\n  }"):
        input_code = input_code.replace("      ),\n    );\n  }\n", "      ),\n    )));\n  }\n")
        content = content[:input_idx] + input_code + content[swipe_idx:]

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Fixed chat_screen.dart successfully!")
