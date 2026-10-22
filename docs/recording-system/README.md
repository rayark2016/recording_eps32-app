# 錄音系統工程文件

本資料夾定義 ESP32-S3 PDM 錄音器與手機 App 的共同工程契約。目標是讓每一次錄音都能從 App 請求、裝置端實際收音、SD 完成 WAV、BLE 傳輸到手機、手機驗證與儲存，全程可追蹤且可診斷。

## 文件導覽

| 文件 | 用途 |
| --- | --- |
| [01-system-architecture.md](01-system-architecture.md) | 系統邊界、元件與資料流。 |
| [02-recording-state-machine.md](02-recording-state-machine.md) | 跨 App 與韌體的錄音狀態機。 |
| [03-ble-protocol-contract.md](03-ble-protocol-contract.md) | BLE 指令、事件、session ID 與文字編碼契約。 |
| [04-firmware-components.md](04-firmware-components.md) | ESP32 韌體元件、責任與健康狀態。 |
| [05-mobile-app-components.md](05-mobile-app-components.md) | Flutter App 元件、UI 狀態與本機儲存責任。 |
| [06-wav-transfer-integrity.md](06-wav-transfer-integrity.md) | WAV 成檔與 BLE 傳輸完整性設計。 |
| [07-observability-and-errors.md](07-observability-and-errors.md) | 狀態快照、錯誤碼與日誌欄位。 |
| [08-test-and-acceptance.md](08-test-and-acceptance.md) | 單元、整合、實機驗收順序與成功條件。 |

## 現況與目標

目前程式已具備 BLE 連線、PDM、SD、WAV 與手機端儲存的個別實作；但跨元件流程仍缺少共同的 session、確認事件、錯誤狀態與傳輸驗證。因此，本文件的 **目標協定** 不代表現況已實作。

開發順序應先實作狀態與觀測，再修改錄音與傳輸流程；不要以 UI 按鈕已變色或檔案存在作為錄音成功的證據。
