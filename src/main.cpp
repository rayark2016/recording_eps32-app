/*
 * src/main.cpp
 *
 * ESP32-S3 SD 卡錄音韌體（馬達實驗室用）
 *
 * 功能：保留 USB Serial 指令，並提供已上架 Pico iOS App 的 BLE 相容協定。
 *       音訊使用已驗證的 PDM/SD 腳位直接寫入 SD 卡 WAV 檔案。
 *
 * 指令（Python → ESP32，以 \n 結尾）：
 *   PING                  → 確認錄音板身分
 *   SD_CHECK              → 確認 SD 與 /recordings/ 目錄就緒
 *   REC_START:<filename>  → 開始錄音（例如 REC_START:TypeA_1_1.wav）
 *   REC_STOP              → 停止錄音
 *   STATUS                → 查詢狀態
 *   LIST                  → 列出 SD 卡檔案
 *   FREE                  → 查詢 SD 卡剩餘空間
 *   DELETE:<filename>     → 刪除指定檔案
 */

#include <Arduino.h>
#include <ArduinoJson.h>
#include <time.h>
#include <sys/time.h>
#include <Preferences.h>
#include "audio_config.h"
#include "ble_manager.h"
#include "i2s_audio.h"
#include "sd_manager.h"
#include "wav_writer.h"

// ====== 狀態定義 ======
enum State { STATE_IDLE, STATE_RECORDING, STATE_SAVING };
static State currentState = STATE_IDLE;

// ====== 物件 ======
static SDManager sdManager;
static WavWriter wavWriter;
static BLEManager bleManager;

// ====== 錄音狀態 ======
static FsFile recordFile;
static String recordFilename;
static String recordPartPath;
static String recordId;
static unsigned long recordStartMs = 0;
static bool timeSynced = false;
static bool recordingWriteFailed = false;
static uint32_t activeStartRequestId = 0;
static uint32_t lastStopRequestId = 0;
static String lastFinalizedFilename;

struct MetadataTransaction {
    bool active = false;
    String recordId;
    uint32_t id = 0;
    uint16_t totalBytes = 0;
    uint16_t nextSequence = 0;
    String payload;
};
static MetadataTransaction metadataTransaction;

// ====== 音訊緩衝區 ======
static int16_t audioBuffer[FRAME_SAMPLES];

// ====== 前向宣告 ======
void handleCommand(const String& cmd);
void startRecording(const String& filename, uint32_t requestId = 0);
void stopRecording(uint32_t requestId = 0);
bool isValidFilename(const String& filename);
bool isValidDeviceCode(const String& deviceCode);
String makeBleFilename();
String formattedTime();
void processBleRequests();
void saveUserData(const String& json);
void processMetadataRequests();
bool saveMetadataPayload(const String& recordId, const String& userDataJson);
void notifyRecorderStatus(uint32_t requestId);
void sendBleRecordList(uint16_t page, uint16_t pageSize);
void sendBleMetadata(const String& wavName);
void handleProvisionCommand(const String& requestedCode);
bool writeDeviceIdentityFile(const String& deviceCode = "");
bool writeAutomaticRecordingMetadata(const String& wavName, unsigned long durationMs);

void setup() {
    Serial.begin(115200);
    delay(1000);

    Serial.println("== recording_controller_node booting ==");
    Serial.println("Commands: PING / IDENTITY / DEVICE_JSON / PROVISION:<code> / SD_CHECK / REC_START:<file> / REC_STOP / STATUS / LIST / FREE / DELETE:<file>");
    Serial.flush();

    // 初始化 SD 卡（重試最多 3 次，與 bluetooth 版對齊）
    bool sdOk = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
        Serial.printf("[SD] Attempt %d/3...\n", attempt);
        if (sdManager.begin()) {
            sdOk = true;
            break;
        }
        delay(500);
    }
    if (!sdOk) {
        Serial.println("ERR:SD_INIT_FAILED");
    }

    // Build the complete GATT database first, but do not advertise yet. A
    // phone must not be allowed to initiate discovery while SD/PDM startup is
    // still monopolising initialization work.
    const bool bleReady = bleManager.begin();
    if (sdOk && !writeDeviceIdentityFile()) {
        Serial.println("WARN:DEVICE_IDENTITY_FILE_WRITE_FAILED");
    }

    // 初始化 I2S PDM 麥克風
    const bool microphoneReady = i2s_up();
    if (!microphoneReady) {
        Serial.println("ERR:PDM_INIT_FAILED");
    }
    if (!bleReady || !bleManager.startAdvertising()) {
        Serial.println("ERR:BLE_ADVERTISING_FAILED");
    } else if (microphoneReady) {
        Serial.println("READY:RECORDER_SD_V1");
    }
    Serial.flush();
}

void loop() {
    processBleRequests();

    // ── 檢查串口指令 ──
    if (Serial.available()) {
        String cmd = Serial.readStringUntil('\n');
        cmd.trim();
        if (cmd.length() > 0) {
            handleCommand(cmd);
        }
    }

    // ── 錄音中：持續讀取 I2S 並寫入 SD 卡 ──
    if (currentState == STATE_RECORDING) {
        size_t bytes_read = i2s_read_samples(audioBuffer, FRAME_BYTES);
        if (bytes_read > 0) {
            size_t samples = bytes_read / sizeof(int16_t);
            if (!wavWriter.writeData(recordFile, audioBuffer, samples)) {
                recordingWriteFailed = true;
                Serial.println("ERR:WAV_WRITE_FAILED");
                bleManager.notifyState("FAILED:SD_WRITE");
                stopRecording(activeStartRequestId);
                return;
            }
        }

        // 超過最大錄音時長則自動停止
        unsigned long elapsed = millis() - recordStartMs;
        if (elapsed > (unsigned long)MAX_RECORD_DURATION_SEC * 1000UL) {
            Serial.println("WARN:MAX_DURATION_REACHED");
            stopRecording(activeStartRequestId);
        }
    }
}

void handleCommand(const String& cmd) {
    if (cmd == "PING") {
        Serial.println("OK:PONG:RECORDER_SD_V1");
        Serial.flush();

    } else if (cmd == "IDENTITY") {
        Serial.print("IDENTITY:");
        Serial.println(bleManager.deviceInfoJson());
        Serial.flush();

    } else if (cmd == "DEVICE_JSON") {
        if (!sdManager.isReady()) {
            Serial.println("DEVICE_JSON:{\"status\":\"error\",\"message\":\"SD_NOT_READY\"}");
        } else {
            FsFile file = sdManager.openForRead("/device.json");
            if (!file.isOpen()) {
                Serial.println("DEVICE_JSON:{\"status\":\"error\",\"message\":\"NOT_FOUND\"}");
            } else {
                String payload;
                while (file.available()) payload += static_cast<char>(file.read());
                sdManager.closeFile(file);
                Serial.print("DEVICE_JSON:");
                Serial.println(payload);
            }
        }
        Serial.flush();

    } else if (cmd.startsWith("PROVISION:")) {
        handleProvisionCommand(cmd.substring(String("PROVISION:").length()));

    } else if (cmd == "SD_CHECK") {
        // The mount plus write/read/delete diagnostic already established that
        // the SD volume is usable.  Do not query freeClusterCount here: on
        // this SdFat/SD-card combination it can stall the command response.
        if (!sdManager.isReady()) {
            Serial.println("ERR:SD_NOT_READY");
        } else {
            Serial.println("OK:SD_READY");
        }
        Serial.flush();

    } else if (cmd.startsWith("REC_START:")) {
        if (currentState == STATE_RECORDING) {
            Serial.println("ERR:ALREADY_RECORDING");
            return;
        }
        String filename = cmd.substring(10);  // "REC_START:" 長度為 10
        filename.trim();
        if (filename.length() == 0) {
            Serial.println("ERR:NO_FILENAME");
            return;
        }
        if (!isValidFilename(filename)) {
            Serial.println("ERR:INVALID_FILENAME");
            return;
        }
        startRecording(filename);

    } else if (cmd == "REC_STOP") {
        if (currentState != STATE_RECORDING) {
            Serial.println("ERR:NOT_RECORDING");
            return;
        }
        stopRecording();

    } else if (cmd == "STATUS") {
        if (currentState == STATE_RECORDING) {
            Serial.printf("RECORDING:%s\n", recordFilename.c_str());
        } else {
            Serial.println("IDLE");
        }
        Serial.flush();

    } else if (cmd == "LIST") {
        sdManager.listFiles();

    } else if (cmd == "FREE") {
        uint64_t freeBytes = sdManager.getFreeSpace();
        Serial.printf("FREE:%llu\n", (unsigned long long)freeBytes);
        Serial.flush();

    } else if (cmd.startsWith("DELETE:")) {
        String filename = cmd.substring(7);
        filename.trim();
        String fullPath = String(RECORDINGS_DIR) + "/" + filename;
        if (sdManager.deleteFile(fullPath)) {
            Serial.println("OK:DELETED");
        } else {
            Serial.println("ERR:NOT_FOUND");
        }
        Serial.flush();

    } else {
        Serial.print("ERR:UNKNOWN:");
        Serial.println(cmd);
        Serial.flush();
    }
}

bool isValidFilename(const String& filename) {
    // Prevent path traversal and retain a portable FAT filename for the
    // computer-side synchronisation notebook.
    if (!filename.endsWith(".wav") || filename.length() > 48) return false;
    for (size_t i = 0; i < filename.length(); ++i) {
        const char ch = filename[i];
        const bool allowed = (ch >= 'a' && ch <= 'z') ||
                             (ch >= 'A' && ch <= 'Z') ||
                             (ch >= '0' && ch <= '9') ||
                             ch == '_' || ch == '-' || ch == '.';
        if (!allowed) return false;
    }
    return true;
}

bool isValidDeviceCode(const String& deviceCode) {
    if (deviceCode.length() < 3 || deviceCode.length() > 24) return false;
    for (size_t i = 0; i < deviceCode.length(); ++i) {
        const char ch = deviceCode[i];
        if (!((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-')) {
            return false;
        }
    }
    return true;
}

void startRecording(const String& filename, uint32_t requestId) {
    // Never create an export that cannot be traced to a provisioned device.
    if (!bleManager.isProvisionLocked()) {
        Serial.println("ERR:DEVICE_UNPROVISIONED");
        bleManager.notifyState("FAILED:DEVICE_UNPROVISIONED");
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"recording\",\"message\":\"Device must be provisioned before recording\"}");
        return;
    }
    if (!sdManager.isReady()) {
        Serial.println("ERR:SD_NOT_READY");
        bleManager.notifyState("FAILED:SD_NOT_READY");
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"storage_status\",\"sd\":\"not_ready\",\"message\":\"SD card not detected; power off, insert the card, then restart\"}");
        return;
    }

    // 組合完整路徑: /recordings/<filename>
    String fullPath = String(RECORDINGS_DIR) + "/" + filename;
    recordFilename = filename;
    recordId = filename.substring(0, filename.length() - 4);
    recordPartPath = fullPath + ".part";
    recordingWriteFailed = false;
    activeStartRequestId = requestId;

    // 開啟檔案
    recordFile = sdManager.openForWrite(recordPartPath);
    if (!recordFile.isOpen()) {
        Serial.println("ERR:FILE_OPEN_FAILED");
        bleManager.notifyState("FAILED:SD_WRITE_OPEN");
        return;
    }

    // 寫入 WAV header
    if (!wavWriter.begin(recordFile, SAMPLE_RATE, CHANNELS, BITS_PER_SAMPLE)) {
        sdManager.closeFile(recordFile);
        sdManager.deleteFile(recordPartPath);
        Serial.println("ERR:WAV_INIT_FAILED");
        return;
    }

    recordStartMs = millis();
    currentState = STATE_RECORDING;
    bleManager.notifyState("錄音中");
    bleManager.notifyConfirm(String("{\"status\":\"success\",\"operation\":\"recording_started\",\"request_id\":") +
        String(requestId) + ",\"record_id\":\"" + recordId + "\",\"filename\":\"" + recordFilename + "\"}");

    Serial.printf("OK:RECORDING:%s\n", filename.c_str());
    Serial.flush();
}

void stopRecording(uint32_t requestId) {
    currentState = STATE_SAVING;
    unsigned long duration_ms = millis() - recordStartMs;

    // Finalizing the RIFF header is the only required completion condition.
    // Audio remains on the recorder SD card; it is not automatically copied
    // over BLE to the phone.
    const bool finalized = !recordingWriteFailed && wavWriter.finalize(recordFile);
    sdManager.closeFile(recordFile);

    currentState = STATE_IDLE;

    if (!finalized) {
        Serial.println("ERR:WAV_FINALIZE_FAILED");
        Serial.flush();
        bleManager.notifyState("FAILED:WAV_FINALIZE");
        bleManager.notifyConfirm("{\"status\":\"error\",\"message\":\"WAV finalize failed\"}");
        bleManager.notifyConfirm(String("{\"status\":\"error\",\"operation\":\"wav_finalized\",\"request_id\":") + String(requestId) +
            ",\"record_id\":\"" + recordId + "\",\"message\":\"WAV write or finalize failed\"}");
        recordFilename = "";
        recordId = "";
        return;
    }

    const String finalPath = String(RECORDINGS_DIR) + "/" + recordFilename;
    if (!sdManager.renameFile(recordPartPath, finalPath)) {
        Serial.println("ERR:WAV_RENAME_FAILED");
        bleManager.notifyState("FAILED:WAV_RENAME");
        bleManager.notifyConfirm(String("{\"status\":\"error\",\"operation\":\"wav_finalized\",\"request_id\":") + String(requestId) +
            ",\"record_id\":\"" + recordId + "\",\"message\":\"WAV rename failed\"}");
        recordFilename = "";
        recordId = "";
        return;
    }

    Serial.printf("OK:SAVED:%s:%lu\n", recordFilename.c_str(), duration_ms);
    Serial.flush();

    if (!writeAutomaticRecordingMetadata(recordFilename, duration_ms)) {
        Serial.println("WARN:RECORDING_METADATA_WRITE_FAILED");
    }

    bleManager.notifyState("WAV_FINALIZED");
    const String info = String("{\"urination_time\":\"") + formattedTime() +
                        "\",\"device_id\":\"" + bleManager.deviceCode() +
                        "\",\"device_code\":\"" + bleManager.deviceCode() +
                        "\",\"hardware_uid\":\"" + bleManager.hardwareUid() +
                        "\",\"firmware_version\":\"" FIRMWARE_VERSION +
                        "\",\"record_id\":\"" + recordId +
                        "\",\"recording_duration_sec\":" + String((duration_ms + 500) / 1000) +
                        ",\"wav_filename\":\"" + recordFilename + "\"}";
    bleManager.notifyRecordingInfo(info);
    bleManager.notifyConfirm((String("{\"status\":\"success\",\"operation\":\"wav_finalized\",\"request_id\":") + String(requestId) +
        ",\"record_id\":\"" + recordId + "\",\"filename\":\"" + recordFilename +
        "\",\"duration_ms\":" + String(duration_ms) + "}").c_str());
    lastStopRequestId = requestId;
    lastFinalizedFilename = recordFilename;

    recordFilename = "";
    recordId = "";
}

void processBleRequests() {
    uint8_t storageRequestId = 0;
    if (bleManager.takeStorageCheckRequest(storageRequestId)) {
        const String response = sdManager.isReady()
            ? String("{\"status\":\"success\",\"operation\":\"storage_status\",\"request_id\":") + String(storageRequestId) + ",\"sd\":\"ready\",\"message\":\"SD card ready\"}"
            : String("{\"status\":\"error\",\"operation\":\"storage_status\",\"request_id\":") + String(storageRequestId) + ",\"sd\":\"not_ready\",\"message\":\"SD card not detected; power off, insert the card, then restart\"}";
        bleManager.notifyConfirm(response);
    }

    uint32_t timestamp = 0;
    if (bleManager.takeTimeSync(timestamp)) {
        timeval now = {static_cast<time_t>(timestamp), 0};
        settimeofday(&now, nullptr);
        setenv("TZ", "CST-8", 1);
        tzset();
        timeSynced = true;
        bleManager.notifyConfirm("{\"status\":\"success\",\"message\":\"Time synchronized\"}");
    }

    uint32_t statusRequestId = 0;
    if (bleManager.takeRecorderStatusRequest(statusRequestId)) notifyRecorderStatus(statusRequestId);

    bool start = false;
    uint32_t requestId = 0;
    if (bleManager.takeRecordingCommand(start, requestId)) {
        if (start) {
            if (currentState != STATE_IDLE) {
                if (requestId == activeStartRequestId) {
                    bleManager.notifyConfirm(String("{\"status\":\"success\",\"operation\":\"recording_started\",\"request_id\":") + String(requestId) +
                        ",\"record_id\":\"" + recordId + "\",\"filename\":\"" + recordFilename + "\"}");
                } else {
                    bleManager.notifyConfirm("{\"status\":\"error\",\"message\":\"Recorder is busy\"}");
                }
            } else {
                Preferences prefs;
                prefs.begin("recorder", false);
                const uint32_t counter = prefs.getULong("record_counter", 0) + 1;
                prefs.putULong("record_counter", counter);
                prefs.end();
                char suffix[16];
                snprintf(suffix, sizeof(suffix), "-R%06lu.wav", static_cast<unsigned long>(counter));
                startRecording(bleManager.deviceCode() + suffix, requestId);
            }
        } else if (currentState == STATE_RECORDING) {
            stopRecording(requestId);
        } else if (requestId != 0 && requestId == lastStopRequestId) {
            bleManager.notifyConfirm(String("{\"status\":\"success\",\"operation\":\"wav_finalized\",\"request_id\":") + String(requestId) +
                ",\"filename\":\"" + lastFinalizedFilename + "\"}");
        } else {
            bleManager.notifyConfirm("{\"status\":\"error\",\"message\":\"Not recording\"}");
        }
    }

    String userData;
    if (bleManager.takeUserData(userData)) saveUserData(userData);
    processMetadataRequests();

    uint16_t page = 0;
    uint16_t pageSize = 20;
    if (bleManager.takeRecordListRequest(page, pageSize)) {
        sendBleRecordList(page, pageSize);
    }

    String metadataFilename;
    if (bleManager.takeMetadataReadRequest(metadataFilename)) {
        sendBleMetadata(metadataFilename);
    }
}

String makeBleFilename() {
    const String prefix = bleManager.deviceCode() + "_";
    if (timeSynced) {
        time_t now = time(nullptr);
        tm local{};
        localtime_r(&now, &local);
        char timestamp[20];
        strftime(timestamp, sizeof(timestamp), "%Y%m%dT%H%M%S", &local);
        return prefix + timestamp + ".wav";
    }
    return prefix + String(millis()) + ".wav";
}

void handleProvisionCommand(const String& requestedCode) {
    String deviceCode = requestedCode;
    deviceCode.trim();
    deviceCode.toUpperCase();
    if (currentState != STATE_IDLE) {
        Serial.println("PROVISION:{\"status\":\"error\",\"message\":\"Recorder is busy\"}");
    } else if (bleManager.isProvisionLocked()) {
        Serial.println("PROVISION:{\"status\":\"error\",\"message\":\"PROVISION_LOCKED\"}");
    } else if (!isValidDeviceCode(deviceCode)) {
        Serial.println("PROVISION:{\"status\":\"error\",\"message\":\"INVALID_DEVICE_CODE\"}");
    } else if (!bleManager.provisionDeviceCode(deviceCode)) {
        Serial.println("PROVISION:{\"status\":\"error\",\"message\":\"PROVISION_FAILED\"}");
    } else {
        // NVS is the identity authority and must be configurable on a bare
        // production board. `device.json` is a later SD-card mirror: setup()
        // writes it automatically when an SD card is inserted and rebooted.
        const bool deviceFileWritten = writeDeviceIdentityFile();
        Serial.print("PROVISION:{\"status\":\"success\",\"device_code\":\"");
        Serial.print(bleManager.deviceCode());
        Serial.print("\",\"hardware_uid\":\"");
        Serial.print(bleManager.hardwareUid());
        Serial.print("\",\"provision_locked\":true,\"device_file_written\":");
        Serial.print(deviceFileWritten ? "true" : "false");
        Serial.println("}");
    }
    Serial.flush();
}

bool writeDeviceIdentityFile(const String& requestedDeviceCode) {
    if (!sdManager.isReady()) return false;
    FsFile file = sdManager.openForWrite("/device.json");
    if (!file.isOpen()) return false;
    JsonDocument identity;
    const String deviceCode = requestedDeviceCode.length() > 0
        ? requestedDeviceCode : bleManager.deviceCode();
    identity["device_id"] = deviceCode;
    identity["device_code"] = deviceCode;
    identity["hardware_uid"] = bleManager.hardwareUid();
    identity["firmware_version"] = FIRMWARE_VERSION;
    const size_t wrote = serializeJson(identity, file);
    sdManager.closeFile(file);
    return wrote > 0;
}

bool writeAutomaticRecordingMetadata(const String& wavName, unsigned long durationMs) {
    if (!sdManager.isReady()) return false;
    const String jsonName = wavName.substring(0, wavName.length() - 4) + ".json";
    FsFile file = sdManager.openForWrite(String(RECORDINGS_DIR) + "/" + jsonName);
    if (!file.isOpen()) return false;

    JsonDocument record;
    record["schema_version"] = "recorder-v2";
    record["record_id"] = wavName.substring(0, wavName.length() - 4);
    record["wav_filename"] = wavName;
    record["recorded_at"] = formattedTime();
    record["recording_duration_sec"] = (durationMs + 500) / 1000;
    record["device_code"] = bleManager.deviceCode();
    record["hardware_uid"] = bleManager.hardwareUid();
    record["firmware_version"] = FIRMWARE_VERSION;
    record["user_data"] = nullptr;
    const size_t wrote = serializeJson(record, file);
    sdManager.closeFile(file);
    return wrote > 0;
}

void notifyRecorderStatus(uint32_t requestId) {
    const char* state = currentState == STATE_RECORDING ? "recording" :
                        currentState == STATE_SAVING ? "finalizing" : "idle";
    const String filename = currentState == STATE_IDLE ? lastFinalizedFilename : recordFilename;
    bleManager.notifyConfirm(String("{\"status\":\"success\",\"operation\":\"recorder_status\",\"request_id\":") +
        String(requestId) + ",\"state\":\"" + state + "\",\"record_id\":\"" + recordId +
        "\",\"filename\":\"" + filename + "\"}");
}

bool saveMetadataPayload(const String& targetRecordId, const String& userDataJson) {
    if (!sdManager.isReady() || targetRecordId.length() == 0 || targetRecordId.length() > 48) return false;
    const String wavName = targetRecordId + ".wav";
    const String wavPath = String(RECORDINGS_DIR) + "/" + wavName;
    if (!sdManager.fileExists(wavPath)) return false;

    JsonDocument userData;
    if (deserializeJson(userData, userDataJson) || !userData.is<JsonObject>()) return false;
    const String jsonPath = String(RECORDINGS_DIR) + "/" + targetRecordId + ".json";
    JsonDocument record;
    FsFile existing = sdManager.openForRead(jsonPath);
    if (existing.isOpen()) {
        if (deserializeJson(record, existing)) record.clear();
        sdManager.closeFile(existing);
    }
    if (record.isNull()) {
        record["schema_version"] = "recorder-v2";
        record["record_id"] = targetRecordId;
        record["wav_filename"] = wavName;
        record["recorded_at"] = formattedTime();
        record["device_code"] = bleManager.deviceCode();
        record["hardware_uid"] = bleManager.hardwareUid();
        record["firmware_version"] = FIRMWARE_VERSION;
    }
    record["user_data"].set(userData);

    const String tempPath = jsonPath + ".tmp";
    FsFile temp = sdManager.openForWrite(tempPath);
    if (!temp.isOpen()) return false;
    const size_t wrote = serializeJson(record, temp);
    sdManager.closeFile(temp);
    if (wrote == 0) {
        sdManager.deleteFile(tempPath);
        return false;
    }
    // SdFat cannot replace an existing FAT name atomically. We only remove
    // the old sidecar after the complete temporary JSON was flushed/closed.
    if (sdManager.fileExists(jsonPath) && !sdManager.deleteFile(jsonPath)) return false;
    if (!sdManager.renameFile(tempPath, jsonPath)) return false;
    return true;
}

void processMetadataRequests() {
    String targetRecordId;
    uint32_t transactionId = 0;
    uint16_t totalBytes = 0;
    if (bleManager.takeMetadataBegin(targetRecordId, transactionId, totalBytes)) {
        metadataTransaction = MetadataTransaction{};
        if (targetRecordId.length() == 0 || targetRecordId.length() > 48 || totalBytes == 0 || totalBytes > 4096) {
            bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"metadata_failed\",\"message\":\"Invalid metadata transaction\"}");
        } else {
            metadataTransaction.active = true;
            metadataTransaction.recordId = targetRecordId;
            metadataTransaction.id = transactionId;
            metadataTransaction.totalBytes = totalBytes;
            bleManager.notifyConfirm(String("{\"status\":\"success\",\"operation\":\"metadata_begin\",\"transaction_id\":") + String(transactionId) + "}");
        }
    }
    uint16_t sequence = 0;
    String payload;
    if (bleManager.takeMetadataChunk(sequence, payload)) {
        if (!metadataTransaction.active || sequence != metadataTransaction.nextSequence ||
            metadataTransaction.payload.length() + payload.length() > metadataTransaction.totalBytes) {
            metadataTransaction.active = false;
            bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"metadata_failed\",\"message\":\"Invalid metadata chunk\"}");
        } else {
            metadataTransaction.payload += payload;
            ++metadataTransaction.nextSequence;
        }
    }
    if (bleManager.takeMetadataCommit(transactionId)) {
        const bool valid = metadataTransaction.active && transactionId == metadataTransaction.id &&
                           metadataTransaction.payload.length() == metadataTransaction.totalBytes;
        const String completedRecordId = metadataTransaction.recordId;
        const bool saved = valid && saveMetadataPayload(completedRecordId, metadataTransaction.payload);
        metadataTransaction = MetadataTransaction{};
        bleManager.notifyConfirm(saved
            ? String("{\"status\":\"success\",\"operation\":\"metadata_saved\",\"record_id\":\"") + completedRecordId +
                "\",\"filename\":\"" + completedRecordId + ".wav\",\"message\":\"Data saved\"}"
            : String("{\"status\":\"error\",\"operation\":\"metadata_failed\",\"message\":\"Metadata was not saved\"}"));
    }
}

String formattedTime() {
    if (!timeSynced) return "1970-01-01 00:00:00";
    time_t now = time(nullptr);
    tm local{};
    localtime_r(&now, &local);
    char result[24];
    strftime(result, sizeof(result), "%Y-%m-%d %H:%M:%S", &local);
    return String(result);
}

void saveUserData(const String& json) {
    JsonDocument appPayload;
    if (deserializeJson(appPayload, json)) {
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"metadata_saved\",\"message\":\"Invalid user data\"}");
        return;
    }
    const String wavName = appPayload["wav_filename"] | "";
    if (!isValidFilename(wavName)) {
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"metadata_saved\",\"message\":\"Invalid filename\"}");
        return;
    }
    const String jsonName = wavName.substring(0, wavName.length() - 4) + ".json";
    const String jsonPath = String(RECORDINGS_DIR) + "/" + jsonName;
    JsonDocument record;
    FsFile existing = sdManager.openForRead(jsonPath);
    if (existing.isOpen()) {
        deserializeJson(record, existing);
        sdManager.closeFile(existing);
    }
    if (record.isNull()) {
        // Recovery path for recordings created by an older firmware.
        record["schema_version"] = "recorder-v2";
        record["record_id"] = wavName.substring(0, wavName.length() - 4);
        record["wav_filename"] = wavName;
        record["recorded_at"] = formattedTime();
        record["device_code"] = bleManager.deviceCode();
        record["hardware_uid"] = bleManager.hardwareUid();
        record["firmware_version"] = FIRMWARE_VERSION;
    }
    FsFile file = sdManager.openForWrite(jsonPath);
    if (!file.isOpen()) {
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"metadata_saved\",\"filename\":\"" + wavName + "\",\"message\":\"SD write failed\"}");
        return;
    }

    // Preserve the automatic recorder identity and recording timestamp; only
    // append the App form data to the sidecar created at WAV finalization.
    record["user_data"].set(appPayload["user_data"]);
    const size_t wrote = serializeJson(record, file);
    sdManager.closeFile(file);
    bleManager.notifyConfirm(wrote > 0
        ? (String("{\"status\":\"success\",\"operation\":\"metadata_saved\",\"filename\":\"") + wavName + "\",\"message\":\"Data saved\"}").c_str()
        : (String("{\"status\":\"error\",\"operation\":\"metadata_saved\",\"filename\":\"") + wavName + "\",\"message\":\"SD write failed\"}").c_str());
}

void sendBleRecordList(uint16_t page, uint16_t pageSize) {
    if (!sdManager.isReady()) {
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"history_list\",\"message\":\"SD not ready\"}");
        return;
    }

    JsonDocument response;
    response["type"] = "record_list";
    response["page"] = page;
    response["page_size"] = pageSize;
    // Do not call freeClusterCount() here. On this verified SdFat/SD-card
    // combination it can stall the command response, which would make the
    // phone wait forever for an otherwise valid history list.
    response["free_bytes"] = nullptr;
    JsonArray records = response["records"].to<JsonArray>();

    FsFile directory;
    if (!directory.open(sdManager.sd().vol(), RECORDINGS_DIR, O_RDONLY) || !directory.isDir()) {
        bleManager.notifyConfirm("{\"status\":\"error\",\"operation\":\"history_list\",\"message\":\"Cannot open recordings directory\"}");
        return;
    }

    uint32_t totalCount = 0;
    uint32_t included = 0;
    FsFile file;
    char name[64];
    while (file.openNext(&directory, O_RDONLY)) {
        if (!file.isDir()) {
            file.getName(name, sizeof(name));
            const String filename(name);
            if (filename.endsWith(".wav")) {
                if (totalCount >= static_cast<uint32_t>(page) * pageSize && included < pageSize) {
                    JsonObject item = records.add<JsonObject>();
                    item["filename"] = filename;
                    item["filesize"] = file.fileSize();
                    const uint32_t bytes = file.fileSize() >= 44 ? file.fileSize() - 44 : 0;
                    item["duration_sec"] = bytes / (SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8));
                    const String metadata = filename.substring(0, filename.length() - 4) + ".json";
                    const String metadataPath = String(RECORDINGS_DIR) + "/" + metadata;
                    const bool metadataSaved = sdManager.fileExists(metadataPath);
                    item["metadata_saved"] = metadataSaved;
                    // The recorder reads this locally from SD once while
                    // constructing the list. This avoids one BLE request per
                    // row just to show a recording time in the App.
                    if (metadataSaved) {
                        FsFile metadataFile = sdManager.openForRead(metadataPath);
                        JsonDocument metadataJson;
                        if (metadataFile.isOpen() && !deserializeJson(metadataJson, metadataFile)) {
                            const char* recordedAt = metadataJson["recorded_at"] | "";
                            if (recordedAt[0] != '\0') item["recorded_at"] = recordedAt;
                        }
                        sdManager.closeFile(metadataFile);
                    }
                    ++included;
                }
                ++totalCount;
            }
        }
        file.close();
    }
    directory.close();
    response["total_count"] = totalCount;

    String payload;
    serializeJson(response, payload);
    bleManager.notifyRecordList(payload);
    bleManager.notifyConfirm("{\"status\":\"success\",\"operation\":\"history_list\",\"message\":\"History list sent\"}");
}

void sendBleMetadata(const String& wavName) {
    JsonDocument response;
    response["type"] = "metadata";
    response["filename"] = wavName;

    if (!isValidFilename(wavName) || !sdManager.isReady()) {
        response["status"] = "error";
        response["message"] = "Invalid filename or SD not ready";
    } else {
        const String jsonName = wavName.substring(0, wavName.length() - 4) + ".json";
        FsFile file = sdManager.openForRead(String(RECORDINGS_DIR) + "/" + jsonName);
        if (file.isOpen()) {
            JsonDocument metadata;
            const DeserializationError error = deserializeJson(metadata, file);
            sdManager.closeFile(file);
            if (error) {
                response["status"] = "error";
                response["message"] = "Metadata JSON is invalid";
            } else {
                response["status"] = "success";
                response["exists"] = true;
                response["metadata"].set(metadata);
            }
        } else {
            // Older recordings may not have a sidecar yet. Return a safe
            // editable skeleton; saving it creates the missing JSON.
            response["status"] = "success";
            response["exists"] = false;
            JsonObject metadata = response["metadata"].to<JsonObject>();
            metadata["schema_version"] = "recorder-v2";
            metadata["record_id"] = wavName.substring(0, wavName.length() - 4);
            metadata["wav_filename"] = wavName;
            metadata["device_code"] = bleManager.deviceCode();
            metadata["hardware_uid"] = bleManager.hardwareUid();
            metadata["firmware_version"] = FIRMWARE_VERSION;
            metadata["user_data"] = nullptr;
        }
    }

    String payload;
    serializeJson(response, payload);
    bleManager.notifyRecordDataJson(payload);
}
