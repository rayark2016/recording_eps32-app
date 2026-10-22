# WAV 成檔與傳輸完整性

## WAV 成檔

```text
open file → write placeholder header → append PCM → finalize header → flush → close
```

WAV 只有 44 bytes 代表只有 header、沒有 PCM data。檔案存在不表示錄音成功；最低成功條件是 `audio_bytes > 0`，並且檔案大小等於 `44 + audio_bytes`。

## Transfer manifest

在任何二進位封包前先送一個 JSON manifest：

```json
{
  "type":"transfer_start",
  "session_id":"b91f...",
  "filename":"REC_20260813_153000.wav",
  "total_bytes":320044,
  "chunk_size":180,
  "total_chunks":1779,
  "crc32":"A83F921C"
}
```

## 二進位封包

每個 payload 都要有不可混淆的 binary header：

```text
magic | session id fragment | sequence | payload length | payload
```

App 必須驗證 sequence 是連續的；發現遺失、重複或長度不符時送 `NACK` 或宣告 `FAILED:TRANSFER:...`。不要以「累積 bytes >= total bytes」作為唯一成功標準。

## 完成確認

```text
ESP32: TRANSFER_COMPLETE
App:   CRC32 + WAV header + file size verified
App:   PHONE_FILE_VERIFIED
ESP32: optional acknowledgement recorded
```

現況傳輸是韌體連續 notify 原始 bytes、App 累積至預期長度，沒有 sequence、checksum 或 app ACK，因此不適合宣稱檔案完整。
