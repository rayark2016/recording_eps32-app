# 多裝置交接與追溯流程

每台裝置使用兩個身分：不可變的 `hardware_uid`（ESP32 eFuse MAC）與可讀的 `device_code`（例如 `PR-001`）。不得以 BLE address 作為唯一長期識別欄位。

## 建檔

1. 燒錄同一版韌體後，使用 USB 連接電腦；客戶 App 沒有設定設備編號的入口。
2. 執行 `tools/flash_and_provision.py`；它先燒錄共用韌體，再讀取 eFuse `hardware_uid`，並只為新 UID 從 `PR-001` 到 `PR-030` 配發第一個未使用編號。
3. 工具將編號寫入 NVS、鎖定設備身分並更新 Registry；新板不需插入或驗證 SD 卡。
4. 將含 `device_code` 與 `hardware_uid` 後六碼的 QR/文字標籤貼在板子與 SD 卡盒。
5. 使用 App 確認唯讀的設備身分與 BLE 名稱 `Pico PR-xxx`；正式開始錄音前再插入 SD 卡並確認 SD 狀態。記錄 firmware version、保管人、位置、SD 卡 ID 與最後健康檢查日期。

若是舊版 App 曾顯示編號、但板子仍回報 `PR-UNASSIGNED` 的遷移板，先以 UID 建立 `hold` Registry 列，再使用：

```bash
python3 tools/provision_device.py \
  --port /dev/cu.usbmodem1201 \
  --registry docs/device-registry.csv \
  --complete-reservation
```

此模式只接受 Registry 中相同 UID 且狀態為 `hold`／`reserved` 的單一列，並只寫入該列既有的設備編號。

## 音檔追溯

每次錄音產生 `PR-001_YYYYMMDDTHHMMSS.wav` 與同名 JSON。JSON 是匯出後的權威來源，至少包含 `record_id`、`device_code`、`hardware_uid`、`firmware_version`、`recorded_at`、`wav_filename` 與表單資料。

## 交接檢查

- App 顯示的設備編號與板上標籤一致。
- `hardware_uid` 與設備總表一致。
- SD 顯示已連接，並完成一筆測試 WAV + JSON。
- 將健康檢查與異常寫入設備總表；不要只靠口頭交接。
