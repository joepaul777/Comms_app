import sys
import re

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update _buildAppBar to be glassmorphism (group and direct)
import_ui = """import 'dart:ui';\n"""
if "import 'dart:ui';" not in content:
    content = re.sub(r"(import 'package:flutter/material.dart';)", r"\1\n" + import_ui, content)

# group app bar
group_pattern = r"""      return AppBar\(
        backgroundColor: AppColors\.bg,
        elevation: 0,
        leading:"""
group_replacement = """      return AppBar(
        backgroundColor: AppColors.bg.withOpacity(0.75),
        elevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(color: Colors.transparent),
          ),
        ),
        leading:"""
content = re.sub(group_pattern, group_replacement, content, count=1)

# direct app bar
direct_pattern = r"""    return AppBar\(
      backgroundColor: AppColors\.bg,
      elevation: 0,
      leading:"""
direct_replacement = """    return AppBar(
      backgroundColor: AppColors.bg.withOpacity(0.75),
      elevation: 0,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(color: Colors.transparent),
        ),
      ),
      leading:"""
content = re.sub(direct_pattern, direct_replacement, content, count=1)

# 2. Update Chat Background
bg_pattern = r"class _DotPatternPainter extends CustomPainter \{.*?  \}\n\}\n"
new_bg = """class _DotPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Draw a subtle gradient background
    final Rect rect = Offset.zero & size;
    final Paint gradientPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.bg,
          AppColors.bg.withOpacity(0.8),
          AppColors.primary.withOpacity(0.05),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, gradientPaint);

    final paint = Paint()
      ..color = AppColors.border.withOpacity(0.2)
      ..style = PaintingStyle.fill;

    const spacing = 32.0;
    const dotRadius = 1.5;

    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
"""
content = re.sub(bg_pattern, new_bg, content, flags=re.DOTALL)

# 3. Update Input Bar
# Carefully replace the start of _buildInputBar
input_start_pattern = r"""  Widget _buildInputBar\(\) \{
    return Container\("""
input_start_replacement = """  Widget _buildInputBar() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container("""
content = re.sub(input_start_pattern, input_start_replacement, content, count=1)

# Replace the decoration inside _buildInputBar
input_dec_pattern = r"""      decoration: const BoxDecoration\(
        color: AppColors\.bgAlt,
        border: Border\("""
input_dec_replacement = """      decoration: BoxDecoration(
        color: AppColors.bgAlt.withOpacity(0.8),
        border: const Border("""
content = re.sub(input_dec_pattern, input_dec_replacement, content, count=1)

# Fix the end of _buildInputBar
# It ends with:
#           ),
#         ],
#       ),
#     );
#   }
# We need to change it to:
#           ),
#         ],
#       ),
#     )));
#   }
input_end_pattern = r"""        \],
      \),
    \);
  \}"""
input_end_replacement = """        ],
      ),
    )));
  }"""
# Since this pattern might match something else, we will be careful, but this is quite specific to the end of _buildInputBar.
content = re.sub(input_end_pattern, input_end_replacement, content, count=1)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated chat_screen.dart design safely!")
