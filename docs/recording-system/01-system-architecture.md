# 系統架構與元件邊界

## 系統資料流

```text
使用者
  ↓
Flutter UI → Recording Controller → BLE Service
                                      ↓
                                  ESP32 BLE Manager
                                      ↓
                              Recorder State Machine
                         ┌────────────┼────────────┐
                         ↓            ↓            ↓
                      PDM/I2S      WAV Writer    SD Manager
                         └──── PCM → WAV 檔案 ────┘
                                      ↓
                              BLE File Transfer
                                      ↓
                           App File Store + Metadata
```

## 元件責任

| 元件 | 唯一責任 | 不應負責 |
| --- | --- | --- |
| UI | 顯示狀態、收集使用者操作 | 推斷裝置端錄音是否成功。 |
| Recording Controller | 將 UI 操作轉為狀態轉換 | 直接解析 BLE 封包。 |
| BLE Service | GATT 讀寫、封包編解碼、session 對應 | 決定錄音業務狀態。 |
| Recorder State Machine | 接受或拒絕 START/STOP，協調硬體元件 | 呈現 UI。 |
| PDM/I2S | 供應 PCM 與回報 sample 健康度 | 建立檔名或傳檔。 |
| SD Manager | mount、open、write、flush、close | 產生 WAV header。 |
| WAV Writer | header、audio byte 計數、finalize | 知道 BLE 狀態。 |
| Transfer Manager | 分段傳送、重送、完整性確認 | 決定音檔格式。 |

## 目前實作對照

韌體已有 `SDManager`、`WavWriter`、`i2s_audio` 與 `BLEManager`；App 已有 `BLEService`、`HomeScreen` 與本機 WAV/JSON 儲存。現況的主要缺口是缺少一個明確的 Recorder State Machine API；多個元件以隱含順序呼叫，失敗結果未統一回報。

## 成功的定義

一次錄音只有同時滿足下列條件才可標為 `SAVED`：

1. 韌體確認收到 PCM sample，且 `audio_bytes > 0`。
2. SD 上 WAV header 已成功回填、檔案已關閉。
3. 手機收到預期長度的 WAV。
4. 手機驗證 WAV 格式與 checksum。
5. 本機 WAV 與 metadata JSON 已寫入成功。
