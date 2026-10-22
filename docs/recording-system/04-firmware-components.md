# 韌體元件設計

## 元件

| 元件 | 現有檔案 | 必要健康訊號 |
| --- | --- | --- |
| Recorder controller | `src/main.cpp` | current state、session、filename、audio bytes。 |
| BLE manager | `src/ble_manager.cpp` | connected、MTU、command received、notify result。 |
| PDM/I2S | `src/i2s_audio.cpp` | ready、first sample time、total bytes、timeout/read error。 |
| SD manager | `src/sd_manager.cpp` | mounted、open result、bytes written、flush/close result。 |
| WAV writer | `src/wav_writer.cpp` | header result、audio byte count、finalize result。 |

## PDM 成功條件

16 kHz、16-bit、mono 的 PCM 預期為 32,000 bytes/s。開始後不得立即宣布 `RECORDING`；必須先收到至少一個有效 sample frame。若啟動後的限定時間內沒有 sample，回報：

```text
FAILED:PDM:NO_SAMPLES
```

## SD/WAV 成功條件

1. SD mounted 且 `/recordings` 可用。
2. WAV 檔案已開啟。
3. 44-byte placeholder header 寫入成功。
4. 每次 PCM write 均檢查回傳值。
5. STOP 時 `finalize()` 成功、header 回填成功、close 成功。
6. `audio_bytes > 0` 且 SD file size = `44 + audio_bytes`。

## 現況缺口

- `main.cpp` 目前忽略 `wavWriter.writeData()` 與 `wavWriter.finalize()` 的回傳值。
- I2S read timeout 回傳 0 bytes，主流程未將持續無 sample 視為失敗。
- 韌體目前只有 `IDLE`、`RECORDING`、`SAVING` 三態，無法區分開檔、首批 sample、header finalize 與傳輸失敗。
