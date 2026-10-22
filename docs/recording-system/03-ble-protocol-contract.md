# BLE 協定契約

## 編碼原則

- 所有控制 command、state 與 error 一律使用 UTF-8 JSON。
- 機器狀態使用 ASCII enum，例如 `RECORDING`；App 負責轉成人類可讀中文。
- 不傳送未標示編碼的中文字串作為協定狀態。
- 二進位 WAV payload 不得以文字解碼或以字串內容猜測格式。

現況注意：韌體傳送 `錄音中`，App 使用 `String.fromCharCodes()` 解碼狀態通知，會把 UTF-8 byte 當 Unicode code point，造成亂碼。此為已確認的協定缺陷。

## 控制訊息範例

```json
{"type":"command","command":"START","session_id":"b91f...","timestamp":1786606200}
```

```json
{"type":"command","command":"STOP","session_id":"b91f..."}
```

## 事件訊息範例

```json
{"type":"event","event":"RECORDING","session_id":"b91f...","filename":"REC_20260813_153000.wav"}
```

```json
{"type":"error","session_id":"b91f...","component":"SD","code":"OPEN_FAILED","recoverable":true}
```

## Command acknowledgement

每一個 command 至少有三個可觀測結果：

```text
REQUEST_SENT → COMMAND_RECEIVED → ACCEPTED or REJECTED
```

`START` 的成功不能以 command write 成功判定，必須等待 `RECORDING` event。`STOP` 的成功不能以 command write 成功判定，必須等待 `WAV_FINALIZED` event。

## GATT 邏輯通道

| 通道 | 資料 | 規則 |
| --- | --- | --- |
| control | command JSON | write with response。 |
| event/status | state、error JSON | notify。 |
| transfer-control | transfer manifest、ACK/NACK | notify + write。 |
| transfer-data | 二進位封包 | notify，帶 session 與 sequence。 |
