# 測試與驗收計畫

## 測試順序

不得直接以完整 UI 流程判定硬體成功。依序驗證：

1. **SD harness**：mount、mkdir、write、read、delete。
2. **PDM harness**：初始化、限定時間內收到 sample、報告 byte count。
3. **WAV harness**：生成 WAV，驗證 header、data size、實際 size。
4. **BLE control**：每一個 START/STOP 都有同 session 的 accepted/rejected event。
5. **BLE transfer**：故意測試多 chunk、sequence、CRC32 與中斷處理。
6. **App local store**：驗證檔案與 metadata 原子寫入。
7. **End-to-end**：真實錄音後比對 ESP32 SD 與手機端 CRC32。

## 最小實機驗收案例

| 案例 | 預期結果 |
| --- | --- |
| START 且 SD 不可用 | `FAILED:SD:NOT_MOUNTED`；App 不進入錄音中。 |
| START 且 PDM 無資料 | `FAILED:PDM:NO_SAMPLES`；WAV 不得標為已儲存。 |
| 正常錄 3 秒 | audio bytes 接近 96,000；WAV size = 96,044 左右。 |
| STOP | 先收到 `WAV_FINALIZED`，再開始 transfer。 |
| transfer 中斷 | App 顯示 transfer failure，不建立 completed record。 |
| 完整 transfer | 手機與 SD 的 size/CRC32 相同，才進入 SAVED。 |

## 每次測試必收集的證據

- session ID
- 韌體 state transition log
- PDM sample/byte count
- SD WAV size 與 WAV header data size
- transfer expected/received chunks 與 CRC32
- App 本機檔案路徑與驗證結果

只有以上證據完整時，才可宣告該次錄音流程通過。
