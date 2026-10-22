# 錄音狀態機

## 為何需要狀態機

`START` 已送出不等於裝置已錄音。系統不能以單一 `bool isRecording` 表示開始、收音、停止、成檔與傳檔的多個階段。

## 共同狀態

```text
IDLE
  └─ START(session) → STARTING
STARTING
  ├─ SD_FILE_OPENED → WAV_HEADER_WRITTEN
  ├─ PDM_SAMPLES_CONFIRMED → RECORDING
  └─ FAILED:<component>:<code> → FAILED
RECORDING
  └─ STOP(session) → FINALIZING
FINALIZING
  ├─ WAV_FINALIZED → TRANSFERRING
  └─ FAILED:WAV:FINALIZE_FAILED → FAILED
TRANSFERRING
  ├─ PHONE_FILE_VERIFIED → SAVED
  └─ FAILED:TRANSFER:<code> → FAILED
SAVED / FAILED
  └─ acknowledge or next START → IDLE
```

## 狀態轉換規則

| 操作 | 允許來源狀態 | 成功結果 | 拒絕結果 |
| --- | --- | --- | --- |
| START | IDLE | STARTING | `FAILED:RECORDER:BUSY` |
| STOP | RECORDING | FINALIZING | `FAILED:RECORDER:NOT_RECORDING` |
| 接收第一批 sample | STARTING | RECORDING | - |
| SD/WAV finalize | FINALIZING | TRANSFERRING | `FAILED:WAV:FINALIZE_FAILED` |
| App 驗證檔案 | TRANSFERRING | SAVED | `FAILED:TRANSFER:CHECKSUM_MISMATCH` |

## Session ID

每次 START 由 App 產生不可重複的 `session_id`。所有 command、event、檔名與傳輸封包都必須攜帶它。App 只能處理與目前 session 相符的訊息，舊 session 的延遲通知必須記錄但不得改變 UI。

## App UI 對應

| 韌體狀態 | UI | 使用者可操作 |
| --- | --- | --- |
| IDLE | 待機 | 開始。 |
| STARTING | 正在準備錄音 | 不可重複開始或停止。 |
| RECORDING | 錄音中 | 停止。 |
| FINALIZING | 正在完成音檔 | 不可操作。 |
| TRANSFERRING | 正在下載音檔 | 不可開始新錄音。 |
| SAVED | 已儲存 | 查看、開始下一筆。 |
| FAILED | 明確錯誤與建議 | 重試或回到待機。 |
