// include/wav_writer.h
#pragma once
#include <Arduino.h>
#include <SdFat.h>
#include "audio_config.h"

#pragma pack(push, 1)
struct WavHeader {
    char riff[4];
    uint32_t fileSize;
    char wave[4];
    char fmt[4];
    uint32_t fmtSize;
    uint16_t audioFormat;
    uint16_t numChannels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char data[4];
    uint32_t dataSize;
};
#pragma pack(pop)

class WavWriter {
public:
    WavWriter();

    bool begin(FsFile& file, uint32_t sampleRate, uint16_t channels, uint16_t bitsPerSample);
    bool writeData(FsFile& file, const int16_t* buffer, size_t samples);
    bool finalize(FsFile& file);

    uint32_t getDataSize() const { return _dataSize; }
    uint32_t getTotalSize() const { return sizeof(WavHeader) + _dataSize; }

private:
    uint32_t _sampleRate;
    uint16_t _channels;
    uint16_t _bitsPerSample;
    uint32_t _dataSize;
    uint32_t _bytesSinceFlush;

    void createHeader(WavHeader& header);
    bool updateHeader(FsFile& file);
};
