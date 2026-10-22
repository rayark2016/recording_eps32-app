#pragma once

#include <Arduino.h>
#include <SdFat.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

// BLE contract intentionally matches the released pico_recorder_app.
class BLEManager {
public:
    // begin() creates the complete GATT database. Advertising is deliberately
    // started separately after recorder hardware initialization, so a phone
    // never discovers a half-started recorder.
    bool begin();
    bool startAdvertising();
    bool isConnected() const { return _connected; }
    void notifyState(const char* state);
    void notifyRecordingInfo(const String& json);
    void notifyRecordList(const String& json);
    void notifyRecordDataJson(const String& json);
    void notifyConfirm(const String& json);
    bool notifyWav(FsFile& file, const String& filename);

    bool takeRecordingCommand(bool& start, uint32_t& requestId);
    bool takeRecorderStatusRequest(uint32_t& requestId);
    bool takeStorageCheckRequest(uint8_t& requestId);
    bool takeTimeSync(uint32_t& timestamp);
    bool takeUserData(String& json);
    bool takeMetadataBegin(String& recordId, uint32_t& transactionId, uint16_t& totalBytes);
    bool takeMetadataChunk(uint16_t& sequence, String& payload);
    bool takeMetadataCommit(uint32_t& transactionId);
    bool takeRecordListRequest(uint16_t& page, uint16_t& pageSize);
    bool takeMetadataReadRequest(String& filename);
    // Provisioning is intentionally USB-Serial-only.  The mobile App can
    // read this identity but has no BLE write path to modify it.
    bool provisionDeviceCode(const String& deviceCode);
    bool isProvisionLocked() const { return _deviceCode != "PR-UNASSIGNED"; }
    const String& deviceCode() const { return _deviceCode; }
    const String& hardwareUid() const { return _hardwareUid; }
    String deviceInfoJson() const;
    void notifyDeviceInfo();

private:
    BLEServer* _server = nullptr;
    BLECharacteristic* _stateChar = nullptr;
    BLECharacteristic* _infoChar = nullptr;
    BLECharacteristic* _confirmChar = nullptr;
    BLECharacteristic* _dataChar = nullptr;
    BLECharacteristic* _listChar = nullptr;
    BLECharacteristic* _deviceConfigChar = nullptr;
    BLEAdvertising* _advertising = nullptr;
    volatile bool _connected = false;
    volatile bool _recordCommandPending = false;
    volatile bool _recordStart = false;
    volatile uint32_t _recordRequestId = 0;
    volatile bool _statusRequestPending = false;
    volatile uint32_t _statusRequestId = 0;
    volatile bool _storageCheckPending = false;
    volatile uint8_t _storageCheckRequestId = 0;
    volatile bool _timePending = false;
    volatile uint32_t _timestamp = 0;
    String _userData;
    volatile bool _userDataPending = false;
    String _metadataRecordId;
    volatile uint32_t _metadataTransactionId = 0;
    volatile uint16_t _metadataTotalBytes = 0;
    volatile bool _metadataBeginPending = false;
    volatile uint16_t _metadataSequence = 0;
    String _metadataChunkPayload;
    volatile bool _metadataChunkPending = false;
    volatile uint32_t _metadataCommitTransactionId = 0;
    volatile bool _metadataCommitPending = false;
    volatile bool _recordListPending = false;
    volatile uint16_t _recordListPage = 0;
    volatile uint16_t _recordListPageSize = 20;
    volatile bool _transferAckPending = false;
    volatile uint16_t _transferAckSequence = 0;
    String _metadataReadFilename;
    volatile bool _metadataReadPending = false;
    String _deviceCode;
    String _hardwareUid;
    String _advertisedName;

    bool waitForTransferAck(uint16_t sequence, uint32_t timeoutMs = 1500);

    class ServerCallbacks;
    class RecordCallbacks;
    class TimeCallbacks;
    class UserDataCallbacks;
    class RecordListCallbacks;
    class TransferCallbacks;
};
