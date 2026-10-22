# 可觀測性與錯誤契約

## 狀態快照

每次 state transition 都應透過 BLE event 與 Serial 記錄同一份資料：

```json
{
  "type":"state",
  "session_id":"b91f...",
  "state":"RECORDING",
  "component_health": {
    "ble":"connected",
    "sd":"mounted",
    "pdm":"samples_ok",
    "wav_audio_bytes":640
  }
}
```

## 錯誤格式

```json
{
  "type":"error",
  "session_id":"b91f...",
  "component":"PDM",
  "code":"NO_SAMPLES",
  "recoverable":true,
  "detail":"No PCM frame within 2000 ms"
}
```

## 初始錯誤碼

| 元件 | Code | 意義 |
| --- | --- | --- |
| BLE | `COMMAND_TIMEOUT` | 指令沒有被裝置確認。 |
| SD | `NOT_MOUNTED` | SD 未初始化。 |
| SD | `OPEN_FAILED` | WAV 或 JSON 檔案無法開啟。 |
| SD | `WRITE_FAILED` | write 回傳長度不符。 |
| PDM | `INIT_FAILED` | PDM driver 初始化失敗。 |
| PDM | `NO_SAMPLES` | 限定時間內沒有 PCM。 |
| WAV | `HEADER_FAILED` | placeholder header 寫入失敗。 |
| WAV | `FINALIZE_FAILED` | 回填 header 或 close 失敗。 |
| TRANSFER | `SEQUENCE_GAP` | 缺少封包。 |
| TRANSFER | `CHECKSUM_MISMATCH` | App 驗證 CRC32 失敗。 |
| PHONE | `FILE_WRITE_FAILED` | App 無法寫入本機檔案。 |

使用者訊息與工程錯誤必須分離。例如 App 可顯示「音檔儲存失敗，請檢查 SD 卡」，但 log 必須保留 `session_id`、`component`、`code` 與 byte counts。
