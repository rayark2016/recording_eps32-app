class WavValidator {
  /// Validates the PCM WAV layout written by this recorder firmware.
  /// The data chunk is expected at byte 36 and its declared size must exactly
  /// match the received bytes. This prevents a truncated BLE transfer being
  /// shown as a saved recording.
  static String? validate(List<int> bytes, {int? expectedFileSize}) {
    if (expectedFileSize != null && bytes.length != expectedFileSize) {
      return '檔案長度不符：收到 ${bytes.length} bytes，預期 $expectedFileSize bytes';
    }
    if (bytes.length < 44) return 'WAV 檔案小於 44 bytes，沒有有效標頭';
    if (_ascii(bytes, 0, 'RIFF') ||
        _ascii(bytes, 8, 'WAVE') ||
        _ascii(bytes, 12, 'fmt ') ||
        _ascii(bytes, 36, 'data')) {
      return 'WAV RIFF/fmt/data 標頭無效';
    }
    final declaredDataSize = _u32le(bytes, 40);
    final actualDataSize = bytes.length - 44;
    if (declaredDataSize != actualDataSize) {
      return 'WAV data 長度不符：標頭 $declaredDataSize bytes，實際 $actualDataSize bytes';
    }
    if (actualDataSize == 0) return 'WAV 沒有音訊資料（僅有檔頭）';
    return null;
  }

  static bool _ascii(List<int> bytes, int offset, String text) {
    for (var index = 0; index < text.length; index++) {
      if (bytes[offset + index] != text.codeUnitAt(index)) return true;
    }
    return false;
  }

  static int _u32le(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
