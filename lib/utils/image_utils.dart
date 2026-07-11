import 'dart:convert';
import 'package:flutter/material.dart';

final Map<String, ImageProvider> _imageCache = {};

ImageProvider getImageProvider(String photoUrl) {
  if (_imageCache.containsKey(photoUrl)) {
    return _imageCache[photoUrl]!;
  }

  ImageProvider provider;
  if (photoUrl.startsWith('data:image')) {
    final base64Str = photoUrl.split(',').last;
    provider = MemoryImage(base64Decode(base64Str));
  } else {
    provider = NetworkImage(photoUrl);
  }

  // Cap cache size to avoid memory leaks
  if (_imageCache.length > 50) {
    _imageCache.remove(_imageCache.keys.first);
  }

  _imageCache[photoUrl] = provider;
  return provider;
}
