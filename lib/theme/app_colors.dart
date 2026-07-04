import 'package:flutter/material.dart';

class AppColors {
  // Primary
  static const Color primary = Color(0xFFFACC15);
  static const Color primaryDark = Color(0xFFEAB308);
  static const Color primaryLight = Color(0xFFFDE68A);

  // Backgrounds
  static const Color bg = Color(0xFF0A0A0A);
  static const Color bgAlt = Color(0xFF171717);
  static const Color bgElevated = Color(0xFF1F1F1F);
  static const Color bgCard = Color(0xFF1A1A1A);

  // Text
  static const Color text = Color(0xFFFAFAFA);
  static const Color textMuted = Color(0xFFA3A3A3);
  static const Color textDark = Color(0xFF0A0A0A);

  // Border
  static const Color border = Color(0xFF262626);
  static const Color borderLight = Color(0xFF333333);

  // Status
  static const Color online = Color(0xFF22C55E);
  static const Color error = Color(0xFFEF4444);
  static const Color missed = Color(0xFFEF4444);
  static const Color incoming = Color(0xFF3B82F6);
  static const Color outgoing = Color(0xFF22C55E);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, primaryDark],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient darkGradient = LinearGradient(
    colors: [bg, bgAlt],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
