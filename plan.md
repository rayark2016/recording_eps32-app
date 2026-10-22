# 30 台 ESP32 Pico Recorder 設備身分與音檔追溯計畫

## 目標

讓 30 台錄音器使用同一份韌體，仍能在 App、BLE、SD 卡與電腦端明確識別設備及每一筆音檔來源。

本計畫選定 **B 方案：USB 電腦端 Provisioning**。設備編號只由電腦端工具分配與寫入；客戶 App 僅能讀取設備資訊，不得設定、修改或重設編號。

## 核心身分模型

| 欄位 | 範例 | 性質 | 用途 |
| --- | --- | --- | --- |
| `hardware_uid` | `D0CF13411A50` | ESP32 eFuse MAC，永久唯一 | 裝置無法混淆時的權威身分 |
| `device_code` | `PR-001` | 人類可讀、可設定 | 板上標籤、App、BLE 與檔名使用 |
| `record_id` | `PR-001_20260817T153700` | 每筆錄音唯一 | WAV 與 metadata 的共同主鍵 |

核心原則：`hardware_uid` 是機器永久身分；`device_code` 是人類可讀編號。`device_code` 寫入 ESP32 NVS，`hardware_uid ↔ device_code` 對照表另存於電腦端 Registry。

## 架構

```text
ESP32 eFuse MAC (hardware_uid)
        ↓
電腦 Registry 對照表
        ↓
PR-001 (device_code)
        ↓ 寫入 NVS
ESP32 每次開機讀取 device_code
        ↓
┌───────────────┬───────────────────────┐
↓               ↓                       ↓
BLE 廣播名稱     App 連線畫面              SD 音檔與 JSON
Pico PR-001     PR-001 + hardware_uid    PR-001_YYYYMMDDTHHMMSS.wav
```

## 韌體設計

1. 30 台全部燒錄同一份韌體；不得為 `PR-001` 到 `PR-030` 個別編譯韌體。
2. 啟動時讀取 ESP32 eFuse MAC，格式化為 12 碼大寫十六進位 `hardware_uid`。
3. 從 NVS namespace `recorder` 讀取 `device_code`；未設定時使用 `PR-UNASSIGNED`。
4. BLE 使用每台板由 eFuse MAC 衍生的唯一 random-static address，不可使用固定 BLE address。
5. BLE 廣播名稱為 `Pico <device_code>`，例如 `Pico PR-001`。
6. USB Serial 僅供電腦端 Provisioning：

   ```text
   IDENTITY          → 回傳 hardware_uid、device_code、provision_locked
   PROVISION:PR-001  → 僅在 PR-UNASSIGNED 時寫入並鎖定編號
   ```

7. 編號僅限 `A-Z`、`0-9`、`-`，長度 3–24；成功後不可覆寫。客戶 App 無可寫入 device code 的 BLE 通道。
8. WAV 命名為 `<device_code>_<YYYYMMDDTHHMMSS>.wav`。
9. 每筆錄音保存同名 JSON sidecar；表單只更新 `user_data`，不得覆蓋自動錄音 metadata。

## SD 卡資料格式

```text
/recordings/PR-001_20260817T153700.wav
/recordings/PR-001_20260817T153700.json
```

根目錄 `device.json`：

```json
{
  "device_id": "PR-001",
  "hardware_uid": "D0CF13411A50",
  "firmware_version": "5.3.1"
}
```

每筆 JSON 至少包含 `schema_version`、`record_id`、`wav_filename`、`recorded_at`、`device_code`、`hardware_uid`、`firmware_version`、`user_data`。

## App 設計

1. 掃描列表優先顯示 `Pico PR-001`。
2. 連線卡顯示唯讀 `device_code`、`hardware_uid` 與 SD 狀態。
3. 只有已連線且 SD 實體檢查成功時才能開始錄音。
4. 客戶 App 不得設定、重設或變更 `device_code`。
5. App 讀取並呈現 Provisioning 結果；它不是設備編號的權威來源。

## 電腦端 Registry 與 Provisioning

Registry 欄位至少為：

```text
device_code,hardware_uid,ble_name,ble_address,firmware_version,
sd_card_id,owner,location,status,last_health_check,notes
```

範本位置：[docs/device-registry-template.csv](docs/device-registry-template.csv)。

日常使用 `tools/flash_and_provision.py`：燒錄共用韌體後讀取 UID，只有新 UID 才配發下一個未使用編號、寫入並鎖定 NVS、更新 Registry。

```bash
python3 tools/flash_and_provision.py \
  --port /dev/cu.usbmodem1201 \
  --registry docs/device-registry.csv
```

交易順序：

```text
燒錄共用韌體
→ 讀取 IDENTITY
→ 查 Registry 是否已有 hardware_uid
→ 保留下一個未配發的 PR 編號
→ 傳送 PROVISION:PR-xxx
→ 讀回 IDENTITY 驗證鎖定狀態
→ 寫入 Registry 為 provisioned
```

UID 已存在且 NVS 與 Registry 相符時回報 `already_provisioned`，絕不重新配號。UID 不一致、重複或 30 個號碼已用盡時必須停止。

## 30 台 Provisioning SOP

1. 燒錄同一份正式韌體。
2. 唯讀檢查 UID；僅 `new_uid` / `PR-UNASSIGNED` 可配號。
3. 寫入並鎖定 NVS，再更新 Registry；Provisioning 不需插入或驗證 SD 卡。
4. App 確認 BLE 名稱、UID 與設備標籤一致。
5. 補上 SD 卡 ID、保管人、位置與健康檢查資料。
6. 正式錄音前插入 SD 卡並確認 SD 已連接；通過驗收後 Registry 標示為 `ready`。

## 驗收標準

- 30 台可見不同 BLE address 與設備編號。
- 任意 WAV 檔名可辨識 `device_code`。
- 任意同名 JSON 可取得 `hardware_uid` 與 firmware version。
- 即使 NVS 被清除，仍可由 UID 從 Registry 找回原本編號。
- SD 卡混放時仍可由 `device.json` 與 sidecar 辨識來源。

## 目前實作狀態

- 已實作 eFuse UID、NVS device code、唯一 random-static BLE address、`Pico <device_code>` 廣播名稱。
- 已實作唯讀 BLE 設備資訊與不可由 App 變更的設備編號。
- 已實作 USB Serial `IDENTITY`、`PROVISION`、`DEVICE_JSON` 協定與 Registry 檔案鎖定。
- 已實作 WAV 設備代碼前綴、同名 JSON sidecar、SD 根目錄 `device.json`。
