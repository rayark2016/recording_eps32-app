// src/sd_manager.cpp
// 精簡版：使用 greiman/SdFat
#include "sd_manager.h"

namespace {
SPIClass sdSpi(FSPI);
}

SDManager::SDManager()
    : _initialized(false),
      _recordingsDir(RECORDINGS_DIR) {
}

bool SDManager::begin() {
    Serial.println("[SD] Initializing SD card...");

    pinMode(SD_CS_PIN, OUTPUT);
    digitalWrite(SD_CS_PIN, HIGH);
    delay(10);
    sdSpi.begin(SD_SCK_PIN, SD_MISO_PIN, SD_MOSI_PIN, SD_CS_PIN);

    SdSpiConfig spiCfg(SD_CS_PIN, SHARED_SPI, SD_SCK_MHZ(SD_SPI_FREQ_MHZ), &sdSpi);
    if (!_sd.begin(spiCfg)) {
        Serial.println("[SD] Card Mount Failed!");
        _sd.initErrorPrint(&Serial);
        _initialized = false;
        return false;
    }

    uint32_t sectors = _sd.card()->sectorCount();
    if (sectors == 0) {
        Serial.println("[SD] No SD card attached");
        _initialized = false;
        return false;
    }

    uint64_t cardSize = (uint64_t)sectors * 512ULL;
    Serial.printf("[SD] Card Size: %lluMB\n", cardSize / (1024 * 1024));

    uint64_t freeBytes = (uint64_t)_sd.vol()->freeClusterCount() * _sd.vol()->bytesPerCluster();
    Serial.printf("[SD] Free: %lluMB\n", freeBytes / (1024 * 1024));

    _initialized = true;
    createRecordingsDir();
    return true;
}

bool SDManager::isReady() {
    if (!_initialized || !_sd.card()) return false;

    // `_initialized` only means the card mounted at boot. A card can be
    // removed afterwards, so issue a real SPI read before reporting it ready.
    // Sector zero is read-only and is safe to use as a lightweight presence
    // check immediately before a recording or a BLE SD-status reply.
    uint8_t sector[512];
    if (!_sd.card()->readSector(0, sector)) {
        Serial.println("[SD] Card no longer responds; marking storage not ready");
        _initialized = false;
        return false;
    }
    return true;
}

bool SDManager::directoryExists(const String& path) {
    FsFile dir;
    if (!dir.open(_sd.vol(), path.c_str(), O_RDONLY)) return false;
    bool isDir = dir.isDir();
    dir.close();
    return isDir;
}

bool SDManager::createRecordingsDir() {
    if (!_initialized) return false;
    if (directoryExists(_recordingsDir)) return true;
    return _sd.mkdir(_recordingsDir.c_str());
}

FsFile SDManager::openForWrite(const String& filename) {
    FsFile file;
    if (!_initialized) {
        Serial.println("[SD] Not initialized");
        return file;
    }
    if (!file.open(_sd.vol(), filename.c_str(), O_WRONLY | O_CREAT | O_TRUNC)) {
        Serial.printf("[SD] Failed to open: %s\n", filename.c_str());
    }
    return file;
}

FsFile SDManager::openForRead(const String& filename) {
    FsFile file;
    if (!_initialized) return file;
    file.open(_sd.vol(), filename.c_str(), O_RDONLY);
    return file;
}

bool SDManager::closeFile(FsFile& file) {
    if (file.isOpen()) {
        file.flush();
        file.close();
        return true;
    }
    return false;
}

bool SDManager::fileExists(const String& filename) {
    if (!_initialized) return false;
    return _sd.exists(filename.c_str());
}

bool SDManager::deleteFile(const String& filename) {
    if (!_initialized) return false;
    return _sd.remove(filename.c_str());
}

bool SDManager::renameFile(const String& from, const String& to) {
    if (!_initialized) return false;
    return _sd.rename(from.c_str(), to.c_str());
}

uint64_t SDManager::getFreeSpace() {
    if (!_initialized) return 0;
    return (uint64_t)_sd.vol()->freeClusterCount() * _sd.vol()->bytesPerCluster();
}

void SDManager::listFiles() {
    if (!_initialized) {
        Serial.println("ERR:SD_NOT_READY");
        return;
    }

    FsFile dir;
    if (!dir.open(_sd.vol(), _recordingsDir.c_str(), O_RDONLY) || !dir.isDir()) {
        Serial.println("END_LIST");
        return;
    }

    FsFile file;
    char name[128];
    while (file.openNext(&dir, O_RDONLY)) {
        if (!file.isDir()) {
            file.getName(name, sizeof(name));
            Serial.printf("%s\t%llu\n", name, (unsigned long long)file.size());
        }
        file.close();
    }
    dir.close();
    Serial.println("END_LIST");
}
