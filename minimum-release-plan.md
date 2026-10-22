# Pico Recorder 最小正式發布版計畫

## 目的

在不實作完整斷電修復、BLE bonding、boot ID、SHA-256 或複雜歷史分頁的前提下，先堵住三種不可接受的結果：

```text
資料毀損
重複錄音
App 誤判儲存成功
```

此計畫完成後才建立新的正式韌體版本並批次燒錄。原本的設備身分計畫見 `plan.md`；完整可靠度後續計畫見 `reliability-freeze-plan.md`。

## 發布範圍

| 項目 | 本版決策 |
| --- | --- |
| 音檔位置 | WAV 與 JSON 僅存 ESP32 SD 卡，不自動下載到手機 |
| 設備身分 | 保留 NVS `device_code`、eFuse `hardware_uid` 與 Registry |
| Metadata 備註 | 最多 **100 個使用者可見字元** |
| Metadata 傳輸 | BEGIN / CHUNK / COMMIT；不可依賴單次 BLE write |
| 重試 | START、STOP 使用 `request_id`，同 ID 必須冪等 |
| 斷線 | timeout 後必須 `GET_STATUS`，不可直接開始下一筆 |

## M1. 唯一 record_id（必做）

### 實作

1. 韌體在 NVS 保存遞增錄音 counter。
2. 每次建立錄音前先遞增並保存 counter，再生成：

   ```text
   PR-001-R000001
   PR-001-R000002
   ```

3. 正式檔案為：

   ```text
   /recordings/PR-001-R000001.wav
   /recordings/PR-001-R000001.json
   ```

4. 時間可保留在 JSON `recorded_at`，但不再是檔名唯一性的唯一依據。

### 驗收

- 同一秒、重連後、重新開機後建立的錄音都不覆寫舊檔。
- 斷電造成 counter 跳號可接受；重複 record ID 不可接受。

## M2. WAV 原子完成與 SD 錯誤（必做）

### 實作

```text
START
→ <record_id>.wav.part
→ 每次音訊寫入檢查結果
→ STOP
→ 更新 WAV header
→ flush
→ close
→ rename 為 <record_id>.wav
→ 才通知 wav_finalized 成功
```

- `writeData`、header 更新、flush、close、rename 任一失敗：狀態為 `failed`，不得建立正式 `.wav`，不得通知成功。
- App 只接受 firmware `wav_finalized` 成功回覆，不可依 BLE write 成功就推論已儲存。
- 本版可保留 `.part` 供人工診斷；自動修復 `.part` 延後。

### Flush

- 音訊資料累積 16–32 KB 或 0.5–1 秒才 flush。
- STOP/finalize 時一定強制 flush。
- 記錄 SD write error 與 I2S read error；任一錯誤不得假報成功。

### 驗收

- SD 寫滿、錄音中拔卡、模擬 write failure：沒有正式 `.wav`，App 顯示失敗。
- 正常 STOP：WAV header、檔案長度與時長一致。

## M3. START / STOP request_id 與 GET_STATUS（必做）

### 協定

```text
START(request_id)
→ recording_started(request_id, record_id, filename)

STOP(request_id)
→ wav_finalized(request_id, record_id, filename, duration_ms)

GET_STATUS(request_id)
→ recorder_status(request_id, idle|recording|finalizing|failed, record_id, filename, reason)
```

### 規則

1. 同一個 START request ID 重送時，回覆原 `recording_started`，不可開第二個檔案。
2. 同一個 STOP request ID 重送時，回覆原 finalized 或 failed 結果。
3. App 的 START、STOP 等待逾時後，先發 `GET_STATUS`：

   ```text
   timeout
   → GET_STATUS
   → recording：維持停止按鈕
   → finalizing：維持等待
   → finalized：進入表單
   → failed / 無法確認：鎖定下一次錄音並顯示錯誤
   ```

4. 必要 notify 訂閱失敗時，App 不可顯示 BLE ready，也不可開放錄音按鈕。

### 驗收

- 模擬 START/STOP notify 遺失，App 不會重複錄音或卡死。
- 錄音中藍牙斷線、重新連線後，App 能用 `GET_STATUS` 顯示真實狀態。

## M4. Metadata：100 字備註、App 說明與安全寫入（必做）

### App UI 規格

備註欄位必須直接顯示以下說明：

```text
備註（最多 100 字；資料將儲存於錄音器 SD 卡）
```

- 欄位最大長度：**100 個使用者可見字元**。
- 顯示即時字數，例如 `36 / 100`。
- 超過上限時，儲存按鈕 disabled 或顯示欄位驗證錯誤。
- 數字欄位要限制合理範圍與位數，避免不必要放大 JSON。

### 傳輸與寫入規格

100 字是 UX 上限，不是 BLE 安全大小保證。完整 metadata 一律使用：

```text
METADATA_BEGIN(record_id, transaction_id, total_bytes)
METADATA_CHUNK(transaction_id, sequence, payload)
METADATA_COMMIT(transaction_id)
```

韌體必須確認：

- `total_bytes <= 4096`
- sequence 連續且完整
- 收到 bytes 等於 `total_bytes`
- UTF-8 JSON 可解析
- `record_id` 對應既有正式 WAV

全部成立後才寫入：

```text
<record_id>.json.tmp
→ flush
→ close
→ replace <record_id>.json
```

任何 chunk 遺失、重複、逾時、JSON 無效或 SD 錯誤，保留舊 JSON、回覆 `metadata_failed`，不得回報成功。

### 驗收

- 100 字中文、英文、emoji 混合備註可成功寫入。
- 101 字不可送出，App 顯示上限提示。
- 降低 MTU、缺少 chunk、重複 chunk、拔卡時，既有 JSON 不受影響。

## 明確延後項目

下列不進入最小正式發布版：

- boot ID
- `CLEAR_ERROR` 完整狀態
- `.part` 自動 WAV 修復與 `recovered.wav`
- history pagination 重構
- BLE bonding／白名單
- SHA-256 metadata hash
- 複雜 sidecar journal

## 發布門檻

1. M1–M4 已完成程式碼、單元測試與 PR-001/PR-002 實機測試。
2. Android 與 iOS 各完成：連線、錄音、斷線重連、表單、歷史查看。
3. SD 未插卡、拔卡、寫滿、正常 180 秒錄音都具明確且正確結果。
4. 韌體版本升級、Git tag、Registry 與燒錄紀錄備份完成。
