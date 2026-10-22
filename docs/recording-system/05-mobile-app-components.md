# Flutter App 元件設計

## 元件

| 元件 | 現有位置 | 責任 |
| --- | --- | --- |
| Permission/Bluetooth gate | `lib/main.dart`、HomeScreen | 管理 Bluetooth adapter 可用性。 |
| Recording controller | `lib/screens/home_screen.dart` | 將使用者操作轉為狀態機操作。 |
| BLE service | `lib/services/ble_service.dart` | GATT、封包、session demux、連線處理。 |
| Recorder UI | `lib/widgets/recording_controls_view.dart` | 只依 controller state 顯示按鈕。 |
| File store | HomeScreen `_saveWavFile` | 原子寫入 WAV、驗證、儲存 metadata。 |
| History | `lib/screens/history_screen.dart` | 讀取完成且已驗證的紀錄。 |

## UI 原則

- 不得在 `recordChar.write([0x01])` 成功後立即顯示錄音中。
- `STARTING`、`FINALIZING`、`TRANSFERRING` 期間必須鎖定開始／停止按鈕。
- UI 只接受相符 `session_id` 的 event。
- `FAILED` 必須顯示使用者可理解的建議，同時保留完整工程錯誤。

## 現況缺口

目前 `_toggleRecording()` 在 `startRecording()` 回傳值為 false 時，仍將 `_isRecording` 設為 true。這會把「BLE write 已嘗試」錯當「韌體已進入錄音」。應以裝置的 `RECORDING` event 作為唯一成功依據。

App 本機儲存前必須驗證：WAV RIFF/WAVE header、data chunk size、實際檔案大小、manifest 的 byte count 及 checksum。
