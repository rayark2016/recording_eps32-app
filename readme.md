# ESP32-S3 SD 錄音控制器

此專案從已驗證的 `motor_sd_firmware` 建立獨立工作副本，供雙 USB Serial 的同步水泵錄音流程使用。PDM 麥克風音訊直接寫入 SD 卡的 `/recordings/<filename>.wav`。

## USB Serial 指令

| 指令 | 回覆 / 功能 |
| --- | --- |
| `PING` | `OK:PONG:RECORDER_SD_V1`，確認錄音板身分。 |
| `SD_CHECK` | `OK:SD_READY` 或 `ERR:SD_NOT_READY`。 |
| `REC_START:<filename>.wav` | 建立 WAV 並開始錄音。檔名僅允許英數、`_`、`-`、`.`，最長 48 字元。 |
| `REC_STOP` | 完成 WAV header、關檔，回覆 `OK:SAVED:<filename>:<duration_ms>`。 |
| `STATUS` | 回覆 `IDLE` 或 `RECORDING:<filename>`。 |

## 與水泵板同步

電腦端 Notebook 必須先送 `SD_CHECK`，接著：

1. 錄音板 `REC_START:<filename>` 並收到 `OK:RECORDING`。
2. 水泵板 `PWM:<seq>:<0-1023>`。
3. 停止時先送水泵 `STOP`，再送錄音板 `REC_STOP`。

這能確保水泵只會在錄音成功開始後作動，且 WAV 在 SD 卡上安全完成。
