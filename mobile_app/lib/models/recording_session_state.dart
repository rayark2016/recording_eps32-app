/// App-side state for one recorder interaction.
///
/// A BLE write only proves that iOS accepted a command.  The UI must wait for
/// the recorder's notification before it calls the recording active.
enum RecordingPhase {
  idle,
  starting,
  recording,
  finalizing,
  savingMetadata,
  transferring,
  saved,
  failed,
}

class RecordingSessionState {
  const RecordingSessionState({
    required this.phase,
    this.sessionId,
    this.filename,
    this.detail,
    this.errorCode,
  });

  const RecordingSessionState.idle()
      : phase = RecordingPhase.idle,
        sessionId = null,
        filename = null,
        detail = null,
        errorCode = null;

  final RecordingPhase phase;
  final String? sessionId;
  final String? filename;
  final String? detail;
  final String? errorCode;

  // A new recording is only safe once the prior workflow has completely
  // returned to idle. In particular, do not permit it while metadata is still
  // awaiting an SD-card confirmation.
  bool get canStart => phase == RecordingPhase.idle;
  bool get canStop => phase == RecordingPhase.recording;
  bool get isBusy => !canStart && phase != RecordingPhase.recording;
}
