import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add imports
imports = """
import 'dart:ui';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/media_service.dart';
import '../../widgets/media_message_widget.dart';
import '../../widgets/audio_message_widget.dart';
"""
if "import '../../widgets/media_message_widget.dart';" not in content:
    content = content.replace("import 'package:flutter/material.dart';", "import 'package:flutter/material.dart';" + imports)

# 2. Add properties to _ChatScreenState
state_start = "class _ChatScreenState extends State<ChatScreen> {"
new_state = """class _ChatScreenState extends State<ChatScreen> {
  // Media state
  final MediaService _mediaService = MediaService();
  final ImagePicker _imagePicker = ImagePicker();
  
  // Audio state
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordingPath;
  bool _isTextFieldEmpty = true;
"""
if "final MediaService _mediaService" not in content:
    content = content.replace(state_start, new_state)

# 3. Add listener to _messageController
init_state_orig = """  void initState() {
    super.initState();
    _loadCurrentUser();"""
init_state_new = """  void initState() {
    super.initState();
    _messageController.addListener(() {
      setState(() {
        _isTextFieldEmpty = _messageController.text.trim().isEmpty;
      });
    });
    _loadCurrentUser();"""
if "_messageController.addListener" not in content:
    content = content.replace(init_state_orig, init_state_new)

# 4. Dispose
dispose_orig = """  void dispose() {
    // Clear active chat so notifications resume
    NotificationService.activeChatRoomId = null;
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }"""
dispose_new = """  void dispose() {
    // Clear active chat so notifications resume
    NotificationService.activeChatRoomId = null;
    _audioRecorder.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }"""
if "_audioRecorder.dispose()" not in content:
    content = content.replace(dispose_orig, dispose_new)

# 5. Media Methods
media_methods = """
  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final dir = await getApplicationDocumentsDirectory();
      _recordingPath = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(),
        path: _recordingPath!,
      );
      setState(() => _isRecording = true);
    }
  }

  Future<void> _stopRecordingAndSend() async {
    if (!_isRecording) return;
    final path = await _audioRecorder.stop();
    setState(() => _isRecording = false);
    
    if (path != null && _currentUid != null) {
      final file = File(path);
      final fileName = path.split('/').last;
      
      final downloadUrl = await _mediaService.uploadMedia(
        file: file,
        messageId: fileName,
        fileName: fileName,
      );
      
      if (downloadUrl != null) {
        _chatService.sendMessage(
          chatRoomId: widget.chatRoom.id,
          senderId: _currentUid!,
          senderName: _currentUser?.name ?? 'You',
          text: 'Voice Message',
          type: MessageType.audio,
          mediaUrl: downloadUrl,
          localFilePath: path,
        );
        _scrollToBottom();
      }
    }
  }

  Future<void> _pickMedia(ImageSource source, bool isVideo) async {
    final XFile? pickedFile = isVideo 
        ? await _imagePicker.pickVideo(source: source)
        : await _imagePicker.pickImage(source: source, imageQuality: 70);

    if (pickedFile != null && _currentUid != null) {
      final file = File(pickedFile.path);
      final fileName = pickedFile.name;
      final type = isVideo ? MessageType.video : MessageType.image;
      
      final downloadUrl = await _mediaService.uploadMedia(
        file: file,
        messageId: fileName,
        fileName: fileName,
      );
      
      if (downloadUrl != null) {
        _chatService.sendMessage(
          chatRoomId: widget.chatRoom.id,
          senderId: _currentUid!,
          senderName: _currentUser?.name ?? 'You',
          text: isVideo ? 'Video' : 'Image',
          type: type,
          mediaUrl: downloadUrl,
          localFilePath: pickedFile.path,
        );
        _scrollToBottom();
      }
    }
  }

  void _showMediaBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: AppColors.primary),
              title: Text('Gallery', style: GoogleFonts.inter(color: AppColors.text)),
              onTap: () {
                Navigator.pop(context);
                _pickMedia(ImageSource.gallery, false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded, color: AppColors.primary),
              title: Text('Camera (Photo)', style: GoogleFonts.inter(color: AppColors.text)),
              onTap: () {
                Navigator.pop(context);
                _pickMedia(ImageSource.camera, false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded, color: AppColors.primary),
              title: Text('Camera (Video)', style: GoogleFonts.inter(color: AppColors.text)),
              onTap: () {
                Navigator.pop(context);
                _pickMedia(ImageSource.camera, true);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _sendMessage() {"""
if "_startRecording" not in content:
    content = content.replace("  void _sendMessage() {", media_methods)

# 6. Build Input Bar
input_bar_orig = """  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgAlt,
        border: Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.primary),
            onPressed: () {},
          ),
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                inputDecorationTheme: const InputDecorationTheme(
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  focusColor: Colors.transparent,
                ),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.border),
                ),
                child: TextField(
                  controller: _messageController,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppColors.text,
                  ),
                  cursorColor: AppColors.primary,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.textMuted,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    filled: false,
                    isDense: true,
                  ),
                  maxLines: 4,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.send_rounded,
                color: AppColors.textDark,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }"""
input_bar_new = """  Widget _buildInputBar() {
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
            color: AppColors.bgAlt.withOpacity(0.8),
            border: const Border(
              top: BorderSide(color: AppColors.border, width: 0.5),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.primary),
                onPressed: _showMediaBottomSheet,
              ),
              Expanded(
                child: Theme(
                  data: Theme.of(context).copyWith(
                    inputDecorationTheme: const InputDecorationTheme(
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      focusColor: Colors.transparent,
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: AppColors.bg,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: TextField(
                      controller: _messageController,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: AppColors.text,
                      ),
                      cursorColor: AppColors.primary,
                      decoration: InputDecoration(
                        hintText: _isRecording ? 'Recording audio...' : 'Type a message...',
                        hintStyle: GoogleFonts.inter(
                          fontSize: 14,
                          color: _isRecording ? AppColors.error : AppColors.textMuted,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        filled: false,
                        isDense: true,
                      ),
                      maxLines: 4,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _sendMessage(),
                      readOnly: _isRecording,
                      contentInsertionConfiguration: ContentInsertionConfiguration(
                        onContentInserted: (KeyboardInsertedContent content) async {
                          if (content.data != null && _currentUid != null) {
                            final dir = await getTemporaryDirectory();
                            final file = File('${dir.path}/gif_${DateTime.now().millisecondsSinceEpoch}.gif');
                            await file.writeAsBytes(content.data!);
                            final fileName = file.path.split('/').last;
                            final downloadUrl = await _mediaService.uploadMedia(
                              file: file,
                              messageId: fileName,
                              fileName: fileName,
                            );
                            if (downloadUrl != null) {
                              _chatService.sendMessage(
                                chatRoomId: widget.chatRoom.id,
                                senderId: _currentUid!,
                                senderName: _currentUser?.name ?? 'You',
                                text: 'GIF',
                                type: MessageType.gif,
                                mediaUrl: downloadUrl,
                                localFilePath: file.path,
                              );
                              _scrollToBottom();
                            }
                          }
                        },
                        allowedMimeTypes: const <String>['image/gif', 'image/png'],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  if (!_isTextFieldEmpty) {
                    _sendMessage();
                  } else {
                    if (_isRecording) {
                      _stopRecordingAndSend();
                    } else {
                      _startRecording();
                    }
                  }
                },
                onLongPressStart: (_) {
                  if (_isTextFieldEmpty) _startRecording();
                },
                onLongPressEnd: (_) {
                  if (_isTextFieldEmpty) _stopRecordingAndSend();
                },
                child: AnimatedContainer(
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }"""
if "_showMediaBottomSheet" not in content:
    content = content.replace(input_bar_orig, input_bar_new)

# 7. Update App Bar to glassmorphism
group_appbar_orig = """      return AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton("""
group_appbar_new = """      return AppBar(
        backgroundColor: AppColors.bg.withOpacity(0.75),
        elevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(color: Colors.transparent),
          ),
        ),
        leading: IconButton("""
content = content.replace(group_appbar_orig, group_appbar_new)

direct_appbar_orig = """    return AppBar(
      backgroundColor: AppColors.bg,
      elevation: 0,
      leading: IconButton("""
direct_appbar_new = """    return AppBar(
      backgroundColor: AppColors.bg.withOpacity(0.75),
      elevation: 0,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(color: Colors.transparent),
        ),
      ),
      leading: IconButton("""
content = content.replace(direct_appbar_orig, direct_appbar_new)

# 8. Update Background Pattern
bg_orig = """class _DotPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border.withOpacity(0.15)
      ..style = PaintingStyle.fill;

    const spacing = 28.0;
    const dotRadius = 1.0;

    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}"""
bg_new = """class _DotPatternPainter extends CustomPainter {
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
}"""
content = content.replace(bg_orig, bg_new)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Applied ALL changes cleanly!")
