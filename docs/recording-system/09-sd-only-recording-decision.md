# SD-only 錄音儲存決策

## 現行產品流程

WAV 是 ESP32 recorder 的主資料，唯一自動儲存位置為 SD 卡：

```text
App START → ESP32 錄音 → SD WAV finalize → App 收到檔名與時長
→ 使用者填寫資料 → metadata JSON 寫回同一張 SD 卡
```

App 不會在停止錄音後自動下載 WAV，也不會因 BLE 音檔傳輸失敗而把一次已完成的 SD 錄音判為失敗。

## 成功定義

錄音成功必須同時具備：

1. `wavWriter.finalize()` 成功。
2. WAV 檔已關閉在 `/recordings/<filename>.wav`。
3. 韌體送出錄音資訊，其中包含相同檔名。

若 finalize 失敗，韌體送出 `FAILED:WAV_FINALIZE`，App 不開啟表單。

## 手機表單

提交表單後，App 將使用者欄位傳回 ESP32；韌體把它寫成與 WAV 同名的 `.json` 側錄檔。取消表單不刪除 SD 卡的 WAV。

## 日後擴充

需要匯出音檔時，應建立獨立的「下載/匯出」功能，並在該功能中使用序號、ACK、CRC、可恢復重傳與明確進度；它不是錄音完成流程的一部分。
