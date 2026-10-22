import 'package:flutter_test/flutter_test.dart';
import 'package:urination_recorder/services/wav_validator.dart';

List<int> validWav({int audioBytes = 4}) {
  final bytes = List<int>.filled(44 + audioBytes, 0);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  bytes.setRange(36, 40, 'data'.codeUnits);
  bytes[40] = audioBytes;
  return bytes;
}

void main() {
  test('accepts a complete recorder WAV', () {
    final wav = validWav();
    expect(WavValidator.validate(wav, expectedFileSize: wav.length), isNull);
  });

  test('rejects a header-only WAV and a truncated transfer', () {
    expect(WavValidator.validate(validWav(audioBytes: 0)), isNotNull);
    expect(WavValidator.validate(validWav(), expectedFileSize: 99), isNotNull);
  });
}
