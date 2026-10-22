# Pico Recorder 正式燒錄前可靠度凍結計畫

## 目標

在批次燒錄其餘板子前，凍結一份可長期使用的韌體與 Android/iOS BLE 協定。WAV 與 JSON 的權威資料保留在 ESP32 SD 卡；不實作音檔自動傳到手機。

Provisioning 已實測成功（`PR-002`），啟動等待屬後續優化，不是本計畫的阻擋項。

## 發布成功條件

```text
WAV 音訊完整寫入
→ WAV header finalize
→ 正式 .wav 原子完成
→ 自動 JSON 原子完成
→ 表單 JSON 完整驗證並原子完成，或使用者明確取消
```

任一項失敗、BLE 斷線、SD 拔除或斷電，都不得顯示「資料已全部儲存」。

## R1. 表單大小與分段傳輸（必修）

1. App 備註限制 **100 個使用者可見字元**；數字欄位限制範圍與位數。
2. App 送出前計算完整 JSON 的 UTF-8 byte 數，顯示明確錯誤。
3. 正式協定不依賴單次 BLE write：

   ```text
   METADATA_BEGIN(transaction_id, filename, total_bytes, hash)
   METADATA_CHUNK(transaction_id, sequence, payload)
   METADATA_COMMIT(transaction_id)
   ```

4. 韌體只在 sequence、總長度與 hash 全部正確時寫入資料；缺 chunk、重複或逾時均捨棄交易。

驗收：100 字中英 emoji、低 MTU、缺 chunk、重複 chunk、錯誤 hash 均有明確且安全結果，不可毀損既有 JSON。

## R2. BLE 可恢復狀態機（必修）

所有狀態變更命令與回覆都必須帶 `request_id`：

```text
START(request_id)       → recording_started(request_id, record_id, filename)
STOP(request_id)        → wav_finalized(request_id, filename, duration_ms)
GET_STATUS(request_id)  → recorder_status(request_id, state, filename, failure_reason)
```

狀態：

```text
idle → starting → recording → finalizing → awaiting_metadata → idle
                              └──────────────→ failed
```

規則：

- 必要 notify 訂閱失敗即視為連線未 ready，錄音按鈕 disabled。
- START、STOP、metadata commit 逾時後，App 發 `GET_STATUS`，不可直接解鎖下一筆錄音。
- 相同 `request_id` 重試只回覆先前結果，不可建立第二個 WAV。
- 斷線時裝置繼續錄音；重連後 App 先讀 `GET_STATUS` 再恢復控制。

驗收：START／STOP 通知遺失、連線中斷、重連、重複按鈕均不會卡死或產生重複檔。

## R3. SD 原子寫入與斷電復原（必修）

1. 錄音先寫 `record_id.wav.part`；`writeData()`、I2S 或 SD 任何錯誤都鎖定失敗，絕不發出成功通知。
2. 成功更新 header、flush、close 後才 rename 成 `.wav`。
3. 自動 JSON 寫 `.json.part`；編輯既有 JSON 寫 `.json.tmp`，成功後才 replace。
4. 開機掃描 `.part`／`.tmp`：可安全修復的 WAV 改名 `.recovered.wav` 並標記 `recovery_status`；其餘標記 `.corrupt`，不列入正常清單。
5. SD 狀態來自實體 I/O；開始錄音、寫入失敗與 metadata commit 前均重新確認。

### Flush 策略

不要每 20 ms flush。以 RAM 緩衝後每 16–32 KB 或 0.5–1 秒 flush，STOP/finalize 時強制 flush。sidecar 必須記錄 I2S 讀取錯誤、SD 寫入錯誤、遺失樣本數與最後成功 flush 時間。

驗收：拔卡、寫滿、模擬 write error、錄音中斷電都不得假報成功；180 秒錄音後 WAV header、長度與 duration 都正確。

## R4. 檔名與時間品質（必修）

- 同一秒兩筆錄音不得覆寫；record ID 加入遞增序號或短碼。
- 未同步時間時 JSON 標記 `time_source: "unsynced"`，不可把 `1970-01-01` 當真實時間。
- 時間同步失敗不阻止具唯一 ID 的離線錄音。

## R5. 客戶資料存取策略（正式交付前決策）

目前附近手機可控制錄音、讀歷史與修改表單。交付客戶前必須選定：

1. **受信任手機模式（建議）**：BLE bonding、首次管理者配對、白名單。
2. **現場單機模式**：保留無配對，但加入 App 操作 PIN 與風險告知。

## 批次燒錄前測試矩陣

| 類別 | 情境 | 通過條件 |
| --- | --- | --- |
| Android / iOS | 權限、掃描、連線、重連 | 正確 UID、SD 與狀態 |
| BLE | START/STOP 重複、通知遺失、斷線 | 無卡死，可由 GET_STATUS 恢復 |
| SD | 未插卡、拔卡、寫滿、斷電 | 不假報成功，不覆寫資料 |
| 音訊 | 180 秒、連續、同秒錄音 | WAV 有效、有 error counter |
| Metadata | 100 字、低 MTU、傳輸錯誤 | 正確寫入或安全拒絕 |
| 歷史 | 0/1/20/超過 20 筆、缺 sidecar | 清單與 recovery 狀態正確 |

## 發布門檻

- R1–R4 完成程式、單元測試與實機測試。
- Android、iOS 都完成相同 BLE 流程驗收。
- R5 已有明確決策。
- 韌體版本升級、Git tag、燒錄 SHA-256 與 Registry 備份完成。
- PR-001、PR-002 各完成「錄音、斷線、重連、表單、歷史」實機驗收。
