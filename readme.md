# ESP32-S3 Pico Recorder

ESP32-S3 錄音器與 Flutter 手機 App 的同一份原始碼專案。錄音器以 PDM 麥克風擷取單聲道音訊，將 WAV 和其 JSON metadata 寫入 SD 卡；手機 App 透過 BLE 負責尋找設備、控制錄音、呈現錄音狀態與填寫使用者表單。

> 本版本**不包含水泵、馬達或 PWM 控制功能**。

## 專案內容

| 路徑 | 用途 |
| --- | --- |
| `src/`、`include/` | ESP32-S3 韌體：PDM/I2S、SD、WAV、BLE 與裝置身分。 |
| `mobile_app/` | Flutter App：裝置掃描、連線、錄音控制、表單與歷史畫面。 |
| `tools/` | USB 燒錄與 Provisioning 工具。 |
| `docs/recording-system/` | 系統架構、BLE 協定與測試準則。 |
| `docs/device-registry-template.csv` | 可複製的設備 Registry 範本。正式 Registry 不提交。 |

## 硬體與韌體

- 開發板：`esp32-s3-devkitc-1`
- 麥克風：PDM，CLK `GPIO1`、DATA `GPIO41`
- SD 卡：SPI，MISO `GPIO12`、SCK `GPIO14`、MOSI `GPIO15`、CS `GPIO16`
- 音訊：16 kHz、單聲道、16-bit PCM，最長 180 秒
- 韌體版本：`5.4.2`

建置與燒錄：

```bash
pio run
pio run --target upload --upload-port <serial-port>
```

例如 macOS 的 `<serial-port>` 常見為 `/dev/cu.usbmodem*`。燒錄後可用下列命令確認 USB Serial 連線：

```text
PING
IDENTITY
SD_CHECK
STATUS
```

## 手機 App 與錄音器的協作

App 是操作介面，不是音檔與設備身分的權威來源。WAV、同名 JSON 與設備資料都以 ESP32 SD 卡為準；App 只能讀取設備身分，不能透過 BLE 變更設備編號。

```text
使用者
  ↓
Flutter App 視窗（掃描、狀態、錄音、表單、歷史）
  ↓ BLE
ESP32-S3（BLE 狀態機、PDM 麥克風、WAV Writer、SD 卡）
  ↓
/recordings/<record_id>.wav + .json
```

### App 視窗／畫面責任

| App 區域 | 主要元件 | 與 ESP32 的協作方式 |
| --- | --- | --- |
| 裝置掃描與連線 | `DeviceScannerView`、`BLEService` | 掃描 `Pico <device_code>`，建立 BLE 連線並訂閱通知。 |
| 連線狀態卡 | `ConnectionStatusCard` | 顯示唯讀 `device_code`、`hardware_uid`、SD 狀態與最後錄音檔名。 |
| 錄音控制 | `RecordingControlsView`、`HomeScreen` | 只有已連線、完成 USB Provisioning、SD 已確認可用時，才可開始錄音。 |
| 使用者表單 | `RecordingFormScreen` | WAV 完成後送出表單 JSON；錄音器確認寫入 SD 後才解除下一次錄音。 |
| 歷史紀錄 | `HistoryScreen` | 透過 BLE 讀取 SD 上的錄音清單與 metadata。 |

### 標準操作流程

1. 使用者在 App 開啟藍牙權限，掃描並選擇 `Pico PR-xxx`。
2. App 建立連線、同步時間、讀取唯讀設備身分，然後以 request ID 查詢 SD 狀態。
3. 僅在設備已 Provisioned 且 SD 回覆 `ready` 時，App 允許開始錄音。
4. App 發出開始請求後，必須等待錄音器回報 `recording_started` 或狀態 `recording`；BLE write 成功本身不是開始成功。
5. 使用者停止錄音後，錄音器完成 WAV header、flush、close 與 `.part` → `.wav` 的原子改名，才回報 `wav_finalized` 與錄音資訊。
6. App 開啟使用者表單，透過 `BEGIN / CHUNK / COMMIT` 寫入 JSON metadata；只有收到 `metadata_saved` 才解除工作流程。

若 SD 拔除、寫入失敗、BLE 斷線或通知逾時，App 不應顯示「已全部儲存」；重新連線後必須先查詢錄音器狀態。

### BLE 協作約定

| 動作 | App → ESP32 | ESP32 → App |
| --- | --- | --- |
| 開始／停止錄音 | Record Control：`0x01`／`0x00` + 32-bit request ID | `recording_started`、`wav_finalized` confirmation。 |
| 查詢 SD | Record Control：`0x02` + request ID | `storage_status` confirmation。 |
| 查詢目前狀態 | Record Control：`0x03` + request ID | `recorder_status` confirmation。 |
| 時間同步 | 4-byte Unix timestamp | 時間同步 confirmation。 |
| 表單 metadata | User Data：`0xB0` BEGIN、`0xB1` CHUNK、`0xB2` COMMIT | `metadata_begin`、`metadata_saved` 或錯誤 confirmation。 |
| 設備身分 | Read Device Config characteristic | `device_code`、`hardware_uid`、`firmware_version`、`provision_locked`。 |

完整 UUID 與封包細節見 [BLE 協定](docs/recording-system/03-ble-protocol-contract.md)。App 端程式入口是 `mobile_app/lib/screens/home_screen.dart` 與 `mobile_app/lib/services/ble_service.dart`。

## App 開發與測試

需求：Flutter/Dart SDK（`pubspec.yaml` 要求 Dart `>=3.0.0 <4.0.0`），以及 Android 實機或 iOS 實機。BLE 功能不能以一般模擬器驗證。

```bash
cd mobile_app
flutter pub get
flutter test
flutter run
```

App 採用 `flutter_blue_plus`。Android 權限位於 `mobile_app/android/app/src/main/AndroidManifest.xml`；iOS 藍牙使用說明位於 `mobile_app/ios/Runner/Info.plist`。

## USB Serial 維護

以下命令以換行結尾，主要供製造、診斷與 Provisioning 使用：

| 指令 | 功能 |
| --- | --- |
| `PING` | 回覆錄音器身分。 |
| `IDENTITY` | 回傳 `hardware_uid`、`device_code`、版本與鎖定狀態。 |
| `PROVISION:<code>` | 僅限未編號設備；寫入後不可由 App 覆寫。 |
| `SD_CHECK` | 回覆 SD 是否可用。 |
| `REC_START:<filename>.wav` | 以指定檔名直接開始 USB Serial 錄音。 |
| `REC_STOP` | 停止並完成 WAV。 |
| `STATUS`、`LIST`、`FREE` | 查詢錄音、檔案清單與可用空間。 |
| `DELETE:<filename>` | 刪除 `/recordings/` 中指定檔案。 |

批次燒錄與配號：

```bash
python3 tools/flash_and_provision.py --port <serial-port> \
  --registry /path/to/private-device-registry.csv
```

請從 `docs/device-registry-template.csv` 建立私有 Registry。它含硬體 UID、設備擁有者與位置等營運資料，已被 `.gitignore` 排除，不應推送至共享 repository。

## 開發規則

- 30 台設備使用同一份韌體；不要把 `PR-001` 至 `PR-030` 寫死在不同 build。
- `hardware_uid` 是 eFuse 的永久身分；`device_code` 是 USB Provisioning 後不可改寫的人類可讀代號。
- 正式 WAV 與 JSON 的權威副本在 SD 卡；不要以手機端 BLE write 成功推論資料已寫入。
- 變更 BLE 命令、confirmation 結構或 UUID 時，必須同步修改韌體、`BLEService`、測試與協定文件。
- 提交前至少執行 `pio run` 與 `cd mobile_app && flutter test`。

## 相關文件

- [錄音系統文件索引](docs/recording-system/README.md)
- [發布前可靠度凍結計畫](reliability-freeze-plan.md)
- [最小正式發布計畫](minimum-release-plan.md)
- [設備身分與追溯計畫](plan.md)
