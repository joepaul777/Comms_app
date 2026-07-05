import 'dart:convert';
import 'package:flutter/material.dart';

ImageProvider getImageProvider(String photoUrl) {
  if (photoUrl.startsWith('data:image')) {
    final base64Str = photoUrl.split(',').last;
    return MemoryImage(base64Decode(base64Str));
  }
  return NetworkImage(photoUrl);
}
