// include/sd_manager.h
// 精簡版 SD 卡管理（使用 greiman/SdFat）
#pragma once
#include <Arduino.h>
#include <SPI.h>
#include <SdFat.h>
#include "audio_config.h"

class SDManager {
public:
    SDManager();

    bool begin();
    bool isReady();
    bool createRecordingsDir();

    FsFile openForWrite(const String& filename);
    FsFile openForRead(const String& filename);
    bool closeFile(FsFile& file);
    bool fileExists(const String& filename);
    bool deleteFile(const String& filename);
    // Rename is used only after a complete temporary file was flushed and
    // closed.  It never touches NVS or device provisioning data.
    bool renameFile(const String& from, const String& to);

    uint64_t getFreeSpace();
    void listFiles();          // 逐行輸出到 Serial

    SdFat& sd() { return _sd; }

private:
    SdFat _sd;
    bool _initialized;
    String _recordingsDir;
    bool directoryExists(const String& path);
};
