import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

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
content = content.replace(input_bar_orig, input_bar_new)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
print("Fixed input bar!")
