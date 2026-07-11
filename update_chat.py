import sys
import re

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Imports
imports = """import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/media_service.dart';
"""
content = re.sub(r"(import 'package:flutter/material.dart';)", r"\1\n" + imports, content)

# 2. State variables
state_vars = """
  // Media state
  final MediaService _mediaService = MediaService();
  final ImagePicker _imagePicker = ImagePicker();
  
  // Audio state
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordingPath;
  bool _isTextFieldEmpty = true;
"""
content = re.sub(r"(  MessageModel\? _replyingTo;)", r"\1\n" + state_vars, content)

# 3. Add listener to text controller in initState
init_state_update = """  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      setState(() {
        _isTextFieldEmpty = _messageController.text.trim().isEmpty;
      });
    });"""
content = re.sub(r"  @override\s*void initState\(\) \{\s*super\.initState\(\);", init_state_update, content)

# 4. Add dispose for audio recorder
dispose_update = """    _audioRecorder.dispose();
    _messageController.dispose();"""
content = re.sub(r"    _messageController\.dispose\(\);", dispose_update, content)

# 5. Add media methods before _sendMessage
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
      final fileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
          text: isVideo ? 'Video' : 'Photo',
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
content = re.sub(r"  void _sendMessage\(\) \{", media_methods, content)

# 6. Replace _buildInputBar
input_bar_pattern = r"  Widget _buildInputBar\(\) \{.*?(?=  \}\n\})  \}"
new_input_bar = """  Widget _buildInputBar() {
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
                    color: (_isRecording ? AppColors.error : AppColors.primary).withValues(alpha: 0.3),
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
    );
  }
"""
content = re.sub(input_bar_pattern, new_input_bar, content, flags=re.DOTALL)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated chat_screen.dart successfully!")
