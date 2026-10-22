// src/wav_writer.cpp
#include "wav_writer.h"

WavWriter::WavWriter()
    : _sampleRate(0), _channels(0), _bitsPerSample(0), _dataSize(0), _bytesSinceFlush(0) {
}

void WavWriter::createHeader(WavHeader& header) {
    memcpy(header.riff, "RIFF", 4);
    header.fileSize = _dataSize + sizeof(WavHeader) - 8;
    memcpy(header.wave, "WAVE", 4);
    memcpy(header.fmt, "fmt ", 4);
    header.fmtSize = 16;
    header.audioFormat = 1;
    header.numChannels = _channels;
    header.sampleRate = _sampleRate;
    header.byteRate = _sampleRate * _channels * (_bitsPerSample / 8);
    header.blockAlign = _channels * (_bitsPerSample / 8);
    header.bitsPerSample = _bitsPerSample;
    memcpy(header.data, "data", 4);
    header.dataSize = _dataSize;
}

bool WavWriter::begin(FsFile& file, uint32_t sampleRate, uint16_t channels, uint16_t bitsPerSample) {
    if (!file.isOpen()) return false;

    _sampleRate = sampleRate;
    _channels = channels;
    _bitsPerSample = bitsPerSample;
    _dataSize = 0;
    _bytesSinceFlush = 0;

    WavHeader header;
    createHeader(header);

    size_t written = file.write((uint8_t*)&header, sizeof(WavHeader));
    if (written != sizeof(WavHeader)) {
        Serial.printf("[WAV] Header write failed: %d/%d\n", written, sizeof(WavHeader));
        return false;
    }

    Serial.printf("[WAV] Header written: %dHz, %dch, %dbit\n",
                  _sampleRate, _channels, _bitsPerSample);
    return true;
}

bool WavWriter::writeData(FsFile& file, const int16_t* buffer, size_t samples) {
    if (!file.isOpen()) return false;

    size_t bytes = samples * sizeof(int16_t);
    size_t written = file.write((uint8_t*)buffer, bytes);

    if (written != bytes) {
        Serial.printf("[WAV] Write error: %d/%d bytes\n", written, bytes);
        return false;
    }

    _dataSize += written;
    // Flushing every 20 ms makes SD writes needlessly fragile. Keep the
    // bounded loss window, and force a final flush in finalize().
    _bytesSinceFlush += written;
    if (_bytesSinceFlush >= 16 * 1024) {
        file.flush();
        _bytesSinceFlush = 0;
    }
    return true;
}

bool WavWriter::updateHeader(FsFile& file) {
    if (!file.isOpen()) return false;
    if (!file.seekSet(0)) return false;

    WavHeader header;
    createHeader(header);

    size_t written = file.write((uint8_t*)&header, sizeof(WavHeader));
    return (written == sizeof(WavHeader));
}

bool WavWriter::finalize(FsFile& file) {
    if (!file.isOpen()) return false;

    Serial.printf("[WAV] Finalizing: %u bytes audio data\n", _dataSize);

    if (!updateHeader(file)) return false;

    file.flush();
    file.seek(file.size());
    file.flush();

    Serial.printf("[WAV] Finalized: total %u bytes\n", getTotalSize());
    return true;
}
