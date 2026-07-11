import sys
import re

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update _buildAppBar to be glassmorphism
import_ui = """import 'dart:ui';\n"""
content = re.sub(r"(import 'package:flutter/material.dart';)", r"\1\n" + import_ui, content)

appbar_pattern = r"  PreferredSizeWidget _buildAppBar\(\) \{.*?  \}\n"
new_appbar = """  PreferredSizeWidget _buildAppBar() {
    if (widget.chatRoom.isGroup) {
      return AppBar(
        backgroundColor: AppColors.bg.withOpacity(0.75),
        elevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(color: Colors.transparent),
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chatRoom.groupName ?? 'Group',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            Text(
              '${widget.chatRoom.participants.length} members',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.text),
            onPressed: () {},
          ),
        ],
      );
    }

    final otherUserId = _getOtherUserId();

    return AppBar(
      backgroundColor: AppColors.bg.withOpacity(0.75),
      elevation: 0,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(color: Colors.transparent),
        ),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
        onPressed: () => Navigator.pop(context),
      ),
      titleSpacing: 0,
      title: FutureBuilder<UserModel?>(
        future: _userService.getUser(otherUserId),
        builder: (context, snapshot) {
          final otherUser = snapshot.data;
          final name = otherUser?.name ?? 'Loading...';
          final photoUrl = otherUser?.photoUrl;
          final isOnline = otherUser?.isOnline ?? false;

          return Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: AppColors.bgElevated,
                  backgroundImage:
                      photoUrl != null ? NetworkImage(photoUrl) : null,
                  child: photoUrl == null
                      ? Text(
                          name[0].toUpperCase(),
                          style: GoogleFonts.outfit(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    if (isOnline)
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Online',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppColors.success,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call_rounded, color: AppColors.primary),
          onPressed: () => _makeCall(CallType.audio),
        ),
        IconButton(
          icon: const Icon(Icons.videocam_rounded, color: AppColors.primary),
          onPressed: () => _makeCall(CallType.video),
        ),
      ],
    );
  }
"""
content = re.sub(appbar_pattern, new_appbar, content, flags=re.DOTALL)

# 2. Update Chat Background to be sleeker
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

# 3. Update Input Bar to have glassmorphism
input_pattern = r"  Widget _buildInputBar\(\) \{.*?\n        decoration: const BoxDecoration\(\n          color: AppColors\.bgAlt,"
new_input = """  Widget _buildInputBar() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.only(
            left: 8,
            right: 8,
            top: 12,
            bottom: MediaQuery.of(context).padding.bottom + 12,
          ),
          decoration: BoxDecoration(
            color: AppColors.bgAlt.withOpacity(0.8),"""
content = re.sub(input_pattern, new_input, content, flags=re.DOTALL)
content = re.sub(r"            color: AppColors\.bgAlt\.withOpacity\(0\.8\),\n          border: Border\(", r"            color: AppColors.bgAlt.withOpacity(0.8),\n            border: const Border(", content)

# 4. We need to wrap the whole Container of _buildInputBar in the end of the method with )
content = re.sub(r"        \],\n      \),\n    \);\n  \}", r"        ],\n      ),\n    )));\n  }", content)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated chat_screen.dart design successfully!")
