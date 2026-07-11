import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Let's fix the extra `)))` at the end of _buildInputBar
# We know the end is:
#       ),
#     )));
#   }
# }
# /// Swipeable wrapper
# We'll replace it with:
#       ),
#     );
#   }
# }
content = content.replace("      ),\n    )));\n  }\n}", "      ),\n    );\n  }\n}")

# 2. Now let's manually add the glassmorphism to _buildInputBar.
# Find `Widget _buildInputBar() {\n    return Container(`
# Replace with `return ClipRect(\n      child: BackdropFilter(\n        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),\n        child: Container(`
content = content.replace("  Widget _buildInputBar() {\n    return Container(", "  Widget _buildInputBar() {\n    return ClipRect(\n      child: BackdropFilter(\n        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),\n        child: Container(")

# 3. Replace the decoration to be glassmorphism
old_dec = """      decoration: const BoxDecoration(
        color: AppColors.bgAlt,
        border: Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),"""
new_dec = """      decoration: BoxDecoration(
        color: AppColors.bgAlt.withOpacity(0.8),
        border: const Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),"""
content = content.replace(old_dec, new_dec)

# 4. We need to add the closing parenthesis for ClipRect and BackdropFilter!
# But wait, earlier we replaced the end with `);\n  }\n}`.
# So we need to change it to `)));\n  }\n}`
content = content.replace("      ),\n    );\n  }\n}", "      ),\n    )));\n  }\n}")

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Fixed _buildInputBar successfully!")
