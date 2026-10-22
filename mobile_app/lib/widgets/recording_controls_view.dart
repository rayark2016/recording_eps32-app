/// recording_controls_view.dart
/// 錄音控制介面 Widget

import 'package:flutter/material.dart';
import '../models/recording_session_state.dart';

class RecordingControlsView extends StatelessWidget {
  final RecordingSessionState recordingState;
  final bool canStartRecording;
  final String? disabledLabel;
  final VoidCallback onToggleRecording;

  const RecordingControlsView({
    super.key,
    required this.recordingState,
    required this.canStartRecording,
    this.disabledLabel,
    required this.onToggleRecording,
  });

  bool get _isRecording => recordingState.phase == RecordingPhase.recording;
  bool get _canTap => canStartRecording || recordingState.canStop;
  bool get _isDisabled => !_canTap;

  String get _statusText {
    switch (recordingState.phase) {
      case RecordingPhase.idle:
        return '準備就緒';
      case RecordingPhase.starting:
        return '等待錄音器確認開始…';
      case RecordingPhase.recording:
        return '錄音中…';
      case RecordingPhase.finalizing:
        return '正在完成 WAV 檔案…';
      case RecordingPhase.savingMetadata:
        return '正在將表單資料儲存到 SD 卡…';
      case RecordingPhase.transferring:
        return '正在下載並驗證音檔…';
      case RecordingPhase.saved:
        return '音檔已驗證並儲存';
      case RecordingPhase.failed:
        return recordingState.detail ?? '錄音流程失敗，請重新開始';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 錄音圖示
          Icon(
            _isRecording ? Icons.fiber_manual_record : Icons.mic,
            size: 100,
            color: _isRecording
                ? Colors.red
                : (recordingState.phase == RecordingPhase.failed
                    ? Colors.red
                    : Colors.blue),
          ),
          const SizedBox(height: 32),

          // 狀態文字
          Text(
            _statusText,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: _isRecording
                  ? Colors.red
                  : (recordingState.phase == RecordingPhase.failed
                      ? Colors.red
                      : Colors.blue),
            ),
          ),
          const SizedBox(height: 48),

          // 錄音按鈕
          ElevatedButton.icon(
            onPressed: _canTap ? onToggleRecording : null,
            icon: Icon(
              recordingState.isBusy
                  ? Icons.hourglass_top
                  : (_isRecording ? Icons.stop : Icons.fiber_manual_record),
            ),
            label: Text(
              _isDisabled
                  ? (disabledLabel ?? '請完成目前流程')
                  : (_isRecording ? '停止錄音' : '開始錄音'),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRecording ? Colors.red : Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 20),
              textStyle: const TextStyle(fontSize: 18),
              disabledBackgroundColor: Colors.grey.shade400,
              disabledForegroundColor: Colors.grey.shade100,
            ),
          ),
        ],
      ),
    );
  }
}
