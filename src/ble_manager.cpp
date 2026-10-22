#include "ble_manager.h"
#include "audio_config.h"
#include <ArduinoJson.h>
#include <Preferences.h>

class BLEManager::ServerCallbacks : public BLEServerCallbacks {
public:
    explicit ServerCallbacks(BLEManager& manager) : _manager(manager) {}
    void onConnect(BLEServer*) override {
        _manager._connected = true;
        Serial.println("[BLE] Client connected");
    }
    void onDisconnect(BLEServer* server) override {
        _manager._connected = false;
        Serial.println("[BLE] Client disconnected; restarting advertising");
        server->startAdvertising();
    }
private:
    BLEManager& _manager;
};

class BLEManager::RecordCallbacks : public BLECharacteristicCallbacks {
public:
    explicit RecordCallbacks(BLEManager& manager) : _manager(manager) {}
    void onWrite(BLECharacteristic* characteristic) override {
        const String value = characteristic->getValue();
        if (!value.isEmpty()) {
            const uint8_t command = static_cast<uint8_t>(value[0]);
            if (command == 0x02) {
                // Byte 1 correlates the response with this exact query.
                // A repeated `SD ready` response is valid, not a duplicate.
                _manager._storageCheckRequestId = value.length() > 1
                    ? static_cast<uint8_t>(value[1]) : 0;
                _manager._storageCheckPending = true;
            } else if (command == 0x03) {
                _manager._statusRequestId = value.length() >= 5
                    ? static_cast<uint8_t>(value[1]) |
                      (static_cast<uint32_t>(static_cast<uint8_t>(value[2])) << 8) |
                      (static_cast<uint32_t>(static_cast<uint8_t>(value[3])) << 16) |
                      (static_cast<uint32_t>(static_cast<uint8_t>(value[4])) << 24) : 0;
                _manager._statusRequestPending = true;
            } else if (command == 0x00 || command == 0x01) {
                _manager._recordStart = command == 0x01;
                _manager._recordRequestId = value.length() >= 5
                    ? static_cast<uint8_t>(value[1]) |
                      (static_cast<uint32_t>(static_cast<uint8_t>(value[2])) << 8) |
                      (static_cast<uint32_t>(static_cast<uint8_t>(value[3])) << 16) |
                      (static_cast<uint32_t>(static_cast<uint8_t>(value[4])) << 24) : 0;
                _manager._recordCommandPending = true;
            }
        }
    }
private:
    BLEManager& _manager;
};

class BLEManager::TimeCallbacks : public BLECharacteristicCallbacks {
public:
    explicit TimeCallbacks(BLEManager& manager) : _manager(manager) {}
    void onWrite(BLECharacteristic* characteristic) override {
        const String value = characteristic->getValue();
        if (value.length() == 4) {
            _manager._timestamp = static_cast<uint8_t>(value[0]) |
                                  (static_cast<uint32_t>(static_cast<uint8_t>(value[1])) << 8) |
                                  (static_cast<uint32_t>(static_cast<uint8_t>(value[2])) << 16) |
                                  (static_cast<uint32_t>(static_cast<uint8_t>(value[3])) << 24);
            _manager._timePending = true;
        }
    }
private:
    BLEManager& _manager;
};

class BLEManager::UserDataCallbacks : public BLECharacteristicCallbacks {
public:
    explicit UserDataCallbacks(BLEManager& manager) : _manager(manager) {}
    void onWrite(BLECharacteristic* characteristic) override {
        const String value = characteristic->getValue();
        if (value.isEmpty()) return;
        const uint8_t type = static_cast<uint8_t>(value[0]);
        // V5.4 metadata protocol. Legacy JSON remains accepted below so old
        // installed clients do not crash, but the new App never uses it.
        if (type == 0xB0) {
            JsonDocument command;
            if (deserializeJson(command, value.substring(1))) return;
            _manager._metadataRecordId = command["record_id"] | "";
            _manager._metadataTransactionId = command["transaction_id"] | 0;
            _manager._metadataTotalBytes = command["total_bytes"] | 0;
            _manager._metadataBeginPending = true;
        } else if (type == 0xB1 && value.length() >= 3) {
            _manager._metadataSequence = static_cast<uint8_t>(value[1]) |
                                         (static_cast<uint16_t>(static_cast<uint8_t>(value[2])) << 8);
            _manager._metadataChunkPayload = value.substring(3);
            _manager._metadataChunkPending = true;
        } else if (type == 0xB2) {
            JsonDocument command;
            if (deserializeJson(command, value.substring(1))) return;
            _manager._metadataCommitTransactionId = command["transaction_id"] | 0;
            _manager._metadataCommitPending = true;
        } else {
            _manager._userData = value;
            _manager._userDataPending = true;
        }
    }
private:
    BLEManager& _manager;
};

class BLEManager::RecordListCallbacks : public BLECharacteristicCallbacks {
public:
    explicit RecordListCallbacks(BLEManager& manager) : _manager(manager) {}
    void onWrite(BLECharacteristic* characteristic) override {
        JsonDocument command;
        if (deserializeJson(command, characteristic->getValue())) return;
        if (command["cmd"] != "LIST") return;
        _manager._recordListPage = command["page"] | 0;
        _manager._recordListPageSize = constrain(command["page_size"] | 20, 1, 50);
        _manager._recordListPending = true;
    }
private:
    BLEManager& _manager;
};

// A transfer packet is accepted only after the phone has written its sequence
// ACK back to the same characteristic. This makes a missing notification an
// observable failure instead of a permanently spinning App UI.
class BLEManager::TransferCallbacks : public BLECharacteristicCallbacks {
public:
    explicit TransferCallbacks(BLEManager& manager) : _manager(manager) {}
    void onWrite(BLECharacteristic* characteristic) override {
        const String value = characteristic->getValue();
        if (value.length() == 3 && static_cast<uint8_t>(value[0]) == 0xA1) {
            _manager._transferAckSequence = static_cast<uint8_t>(value[1]) |
                                            (static_cast<uint16_t>(static_cast<uint8_t>(value[2])) << 8);
            _manager._transferAckPending = true;
            return;
        }
        JsonDocument command;
        if (deserializeJson(command, value)) return;
        if (command["cmd"] != "READ_METADATA") return;
        const char* filename = command["filename"] | "";
        _manager._metadataReadFilename = filename;
        _manager._metadataReadPending = true;
    }
private:
    BLEManager& _manager;
};

bool BLEManager::begin() {
    const uint64_t efuseMac = ESP.getEfuseMac();
    char uid[13];
    // ESP.getEfuseMac() stores the Wi-Fi MAC with the first printed octet in
    // the least-significant byte. Format explicit bytes so `hardware_uid`
    // matches the conventional MAC shown by esptool and the Registry.
    snprintf(uid, sizeof(uid), "%02X%02X%02X%02X%02X%02X",
             static_cast<uint8_t>(efuseMac),
             static_cast<uint8_t>(efuseMac >> 8),
             static_cast<uint8_t>(efuseMac >> 16),
             static_cast<uint8_t>(efuseMac >> 24),
             static_cast<uint8_t>(efuseMac >> 32),
             static_cast<uint8_t>(efuseMac >> 40));
    _hardwareUid = uid;

    Preferences preferences;
    preferences.begin("recorder", true);
    _deviceCode = preferences.getString("device_code", "PR-UNASSIGNED");
    preferences.end();
    _advertisedName = String("Pico ") + _deviceCode;

    BLEDevice::init(_advertisedName.c_str());
    // Use a stable *per-board* random-static address. The previous fixed
    // address was useful for a one-board GATT-cache migration, but would make
    // every one of 30 recorders appear to be the same BLE peripheral.
    uint8_t appCompatibleAddress[] = {
        static_cast<uint8_t>(efuseMac),
        static_cast<uint8_t>(efuseMac >> 8),
        static_cast<uint8_t>(efuseMac >> 16),
        static_cast<uint8_t>(efuseMac >> 24),
        static_cast<uint8_t>(efuseMac >> 32),
        static_cast<uint8_t>((efuseMac >> 40) | 0xC0), // random-static bits
    };
    BLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);
    BLEDevice::setOwnAddr(appCompatibleAddress);
    BLEDevice::setMTU(BLE_MTU_SIZE);
    _server = BLEDevice::createServer();
    _server->setCallbacks(new ServerCallbacks(*this));
    BLEService* service = _server->createService(BLE_SERVICE_UUID);

    BLECharacteristic* record = service->createCharacteristic(BLE_RECORD_CTRL_UUID, BLECharacteristic::PROPERTY_WRITE);
    record->setCallbacks(new RecordCallbacks(*this));
    _stateChar = service->createCharacteristic(BLE_SYSTEM_STATE_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    _infoChar = service->createCharacteristic(BLE_RECORD_INFO_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    BLECharacteristic* userData = service->createCharacteristic(BLE_USER_DATA_UUID, BLECharacteristic::PROPERTY_WRITE);
    userData->setCallbacks(new UserDataCallbacks(*this));
    BLECharacteristic* time = service->createCharacteristic(BLE_TIME_SYNC_UUID, BLECharacteristic::PROPERTY_WRITE);
    time->setCallbacks(new TimeCallbacks(*this));
    _confirmChar = service->createCharacteristic(BLE_CONFIRM_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    _listChar = service->createCharacteristic(BLE_RECORD_LIST_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
    _listChar->setCallbacks(new RecordListCallbacks(*this));
    _dataChar = service->createCharacteristic(BLE_RECORD_DATA_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
    _dataChar->setCallbacks(new TransferCallbacks(*this));
    // Kept at the established UUID for App compatibility, but it is now
    // explicitly read-only. Provisioning happens only through USB Serial.
    _deviceConfigChar = service->createCharacteristic(BLE_DEVICE_CONFIG_UUID,
        BLECharacteristic::PROPERTY_READ);
    _deviceConfigChar->setValue(deviceInfoJson().c_str());
    service->start();

    _advertising = BLEDevice::getAdvertising();
    // Explicitly include the App-visible name.  The 128-bit service UUID is
    // kept in the advertising packet and the name moves to scan response when
    // necessary, which is the layout iOS active scans expect.
    _advertising->setName(_advertisedName.c_str());
    _advertising->addServiceUUID(BLE_SERVICE_UUID);
    _advertising->setScanResponse(true);
    _advertising->setMinInterval(0x20);
    _advertising->setMaxInterval(0x40);
    _advertising->setMinPreferred(0x06);
    _advertising->setMinPreferred(0x12);
    Serial.printf("[BLE] GATT ready as %s, hardware UID %s; advertising deferred\n",
                  _advertisedName.c_str(), _hardwareUid.c_str());
    return true;
}

bool BLEManager::startAdvertising() {
    if (!_advertising) return false;
    const bool started = _advertising->start();
    Serial.printf("[BLE] Advertising as %s: %s\n", _advertisedName.c_str(),
                  started ? "started" : "failed");
    return started;
}

void BLEManager::notifyState(const char* state) {
    if (_connected && _stateChar) { _stateChar->setValue(state); _stateChar->notify(); }
}

void BLEManager::notifyRecordingInfo(const String& json) {
    if (!_connected || !_infoChar) return;
    const String packet = "0/1:" + json;
    _infoChar->setValue(packet.c_str());
    _infoChar->notify();
}

void BLEManager::notifyRecordList(const String& json) {
    if (!_connected || !_listChar) return;
    static constexpr size_t kPayloadBytes = 140;
    const size_t total = (json.length() + kPayloadBytes - 1) / kPayloadBytes;
    for (size_t index = 0; index < total && _connected; ++index) {
        const size_t offset = index * kPayloadBytes;
        const String packet = String(index) + "/" + String(total) + ":" +
                              json.substring(offset, offset + kPayloadBytes);
        _listChar->setValue(packet.c_str());
        _listChar->notify();
        delay(15);
    }
}

void BLEManager::notifyRecordDataJson(const String& json) {
    if (!_connected || !_dataChar) return;
    static constexpr size_t kPayloadBytes = 140;
    const size_t total = (json.length() + kPayloadBytes - 1) / kPayloadBytes;
    for (size_t index = 0; index < total && _connected; ++index) {
        const size_t offset = index * kPayloadBytes;
        const String packet = String(index) + "/" + String(total) + ":" +
                              json.substring(offset, offset + kPayloadBytes);
        _dataChar->setValue(packet.c_str());
        _dataChar->notify();
        delay(15);
    }
}

void BLEManager::notifyConfirm(const String& json) {
    if (_connected && _confirmChar) { _confirmChar->setValue(json.c_str()); _confirmChar->notify(); }
}

String BLEManager::deviceInfoJson() const {
    return String("{\"device_code\":\"") + _deviceCode +
           "\",\"hardware_uid\":\"" + _hardwareUid +
           "\",\"firmware_version\":\"" FIRMWARE_VERSION
           "\",\"provision_locked\":" + (isProvisionLocked() ? "true" : "false") + "}";
}

void BLEManager::notifyDeviceInfo() {
    if (!_deviceConfigChar) return;
    const String info = deviceInfoJson();
    _deviceConfigChar->setValue(info.c_str());
}

bool BLEManager::waitForTransferAck(uint16_t sequence, uint32_t timeoutMs) {
    const uint32_t started = millis();
    while (_connected && millis() - started < timeoutMs) {
        if (_transferAckPending && _transferAckSequence == sequence) {
            _transferAckPending = false;
            return true;
        }
        delay(5);
    }
    return false;
}

bool BLEManager::notifyWav(FsFile& file, const String& filename) {
    if (!_connected || !_dataChar || !file.isOpen()) return false;
    const uint32_t size = file.fileSize();
    static constexpr size_t kPayloadBytes = 150; // fits the iPhone ATT MTU with a 2-byte sequence.
    const uint32_t chunks = (size + kPayloadBytes - 1) / kPayloadBytes;
    const String header = String("{\"type\":\"wav_manifest\",\"filename\":\"") + filename +
                          "\",\"filesize\":" + String(size) + ",\"chunks\":" + String(chunks) +
                          ",\"chunk_payload_size\":" + String(kPayloadBytes) + "}";
    _transferAckPending = false;
    _dataChar->setValue(header.c_str());
    _dataChar->notify();
    if (!waitForTransferAck(0xFFFF)) return false;

    uint8_t buffer[kPayloadBytes + 2];
    uint16_t sequence = 0;
    while (_connected && file.available()) {
        const int bytes = file.read(buffer + 2, kPayloadBytes);
        if (bytes <= 0) return false;
        buffer[0] = sequence & 0xFF;
        buffer[1] = (sequence >> 8) & 0xFF;
        _transferAckPending = false;
        _dataChar->setValue(buffer, bytes + 2);
        _dataChar->notify();
        if (!waitForTransferAck(sequence)) return false;
        ++sequence;
    }
    return sequence == chunks;
}

bool BLEManager::takeRecordingCommand(bool& start, uint32_t& requestId) {
    if (!_recordCommandPending) return false;
    start = _recordStart;
    requestId = _recordRequestId;
    _recordCommandPending = false;
    return true;
}

bool BLEManager::takeRecorderStatusRequest(uint32_t& requestId) {
    if (!_statusRequestPending) return false;
    requestId = _statusRequestId;
    _statusRequestPending = false;
    return true;
}

bool BLEManager::takeStorageCheckRequest(uint8_t& requestId) {
    if (!_storageCheckPending) return false;
    requestId = _storageCheckRequestId;
    _storageCheckPending = false;
    return true;
}

bool BLEManager::takeTimeSync(uint32_t& timestamp) {
    if (!_timePending) return false;
    timestamp = _timestamp;
    _timePending = false;
    return true;
}

bool BLEManager::takeUserData(String& json) {
    if (!_userDataPending) return false;
    json = _userData;
    _userDataPending = false;
    return true;
}

bool BLEManager::takeMetadataBegin(String& recordId, uint32_t& transactionId, uint16_t& totalBytes) {
    if (!_metadataBeginPending) return false;
    recordId = _metadataRecordId; transactionId = _metadataTransactionId; totalBytes = _metadataTotalBytes;
    _metadataBeginPending = false;
    return true;
}

bool BLEManager::takeMetadataChunk(uint16_t& sequence, String& payload) {
    if (!_metadataChunkPending) return false;
    sequence = _metadataSequence; payload = _metadataChunkPayload;
    _metadataChunkPending = false;
    return true;
}

bool BLEManager::takeMetadataCommit(uint32_t& transactionId) {
    if (!_metadataCommitPending) return false;
    transactionId = _metadataCommitTransactionId;
    _metadataCommitPending = false;
    return true;
}

bool BLEManager::takeRecordListRequest(uint16_t& page, uint16_t& pageSize) {
    if (!_recordListPending) return false;
    page = _recordListPage;
    pageSize = _recordListPageSize;
    _recordListPending = false;
    return true;
}

bool BLEManager::takeMetadataReadRequest(String& filename) {
    if (!_metadataReadPending) return false;
    filename = _metadataReadFilename;
    _metadataReadPending = false;
    return true;
}

bool BLEManager::provisionDeviceCode(const String& value) {
    // A customer-visible identity cannot be overwritten. A controlled repair
    // workflow must clear NVS separately and leave an audit record.
    if (isProvisionLocked()) return false;
    String normalized = value;
    normalized.trim();
    normalized.toUpperCase();
    if (normalized.length() < 3 || normalized.length() > 24) return false;
    for (size_t i = 0; i < normalized.length(); ++i) {
        const char ch = normalized[i];
        const bool allowed = (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-';
        if (!allowed) return false;
    }

    Preferences preferences;
    if (!preferences.begin("recorder", false)) return false;
    const size_t saved = preferences.putString("device_code", normalized);
    preferences.end();
    if (saved != normalized.length()) return false;

    _deviceCode = normalized;
    _advertisedName = String("Pico ") + _deviceCode;
    if (_advertising) {
        // Provisioning happens over USB, so immediately replace the old
        // PR-UNASSIGNED advertisement instead of requiring a power cycle.
        _advertising->stop();
        _advertising->setName(_advertisedName.c_str());
        _advertising->start();
    }
    notifyDeviceInfo();
    Serial.printf("[BLE] Device code provisioned as %s; advertising restarted\n", _deviceCode.c_str());
    return true;
}
