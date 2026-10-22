# Mobile App - Flutter 應用程式

ESP32 Pico 藍牙排尿記錄系統的手機應用程式。

## 功能特色

- 藍牙裝置掃描與連接
- 自動時間同步
- 錄音控制（開始/停止）
- 排尿狀態選擇
- 記錄列表查看（待實作）
- 檔案下載功能（待實作）

## 開發環境需求

- Flutter SDK 3.0+
- Dart 3.0+
- Android Studio / Xcode
- Android SDK (Android) / Xcode (iOS)

## 安裝步驟

### 1. 安裝依賴套件

```bash
cd mobile_app
flutter pub get
```

### 2. 設定權限

#### Android
已在 `android/app/src/main/AndroidManifest.xml` 設定以下權限：
- BLUETOOTH
- BLUETOOTH_ADMIN
- BLUETOOTH_SCAN
- BLUETOOTH_CONNECT
- ACCESS_FINE_LOCATION

#### iOS
已在 `ios/Runner/Info.plist` 設定藍牙權限說明。

### 3. 執行 APP

```bash
# 連接手機或啟動模擬器

# Android
flutter run

# iOS (需要 macOS)
flutter run
```

## 專案結構

```
lib/
├── main.dart                    # APP 入口
├── models/
│   ├── recording.dart           # 錄音記錄模型
│   └── urination_state.dart     # 排尿狀態定義
├── services/
│   └── ble_service.dart         # 藍牙服務管理
├── screens/
│   └── home_screen.dart         # 主畫面
└── widgets/                     # 自訂元件（待擴充）
```

## 使用說明

### 1. 連接 ESP32 裝置

1. 開啟 APP
2. 點擊「掃描裝置」按鈕
3. 選擇 "ESP32_Pico_Recorder" 裝置
4. 等待連接完成與時間同步

### 2. 錄音

1. 從下拉選單選擇排尿狀態
2. 點擊「開始錄音」按鈕
3. 進行排尿錄音
4. 點擊「停止錄音」按鈕
5. 系統會自動儲存並顯示確認訊息

### 3. 查看記錄（待實作）

目前版本尚未實作記錄列表與下載功能，後續版本將加入。

## 藍牙通訊協定

### UUID 定義

| 功能 | UUID |
|------|------|
| Service | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |
| 錄音控制 | `4fafc201-1fb5-459e-8fcc-c5c9c331914c` |
| 系統狀態 | `4fafc201-1fb5-459e-8fcc-c5c9c331914d` |
| 錄音資訊 | `4fafc201-1fb5-459e-8fcc-c5c9c331914e` |
| 使用者資料 | `4fafc201-1fb5-459e-8fcc-c5c9c331914f` |
| 時間同步 | `4fafc201-1fb5-459e-8fcc-c5c9c3319150` |
| 確認訊息 | `4fafc201-1fb5-459e-8fcc-c5c9c3319151` |
| 記錄列表 | `4fafc201-1fb5-459e-8fcc-c5c9c3319152` |
| 記錄資料 | `4fafc201-1fb5-459e-8fcc-c5c9c3319153` |

## 待實作功能

- [ ] 記錄列表畫面
- [ ] 單筆記錄詳細資訊
- [ ] WAV/JSON 檔案下載
- [ ] 本地檔案管理
- [ ] 音訊播放功能
- [ ] 使用者資料表單（年齡、性別等）
- [ ] 記錄編輯功能
- [ ] 統計與分析功能

## 常見問題

### Q: 無法掃描到裝置
A:
1. 確認 ESP32 已開機並運作正常
2. 確認手機藍牙已開啟
3. 確認 APP 已取得藍牙與定位權限
4. 重啟 APP 或手機藍牙

### Q: 連接失敗
A:
1. 確認裝置名稱包含 "Pico_Recorder"
2. 嘗試重新掃描與連接
3. 重啟 ESP32

### Q: 無法開始錄音
A:
1. 確認時間已同步（連接後會自動同步）
2. 確認 ESP32 Flash 有足夠空間
3. 檢查系統狀態是否為「待機中」

## 開發備註

- 使用 `flutter_blue_plus` 套件進行藍牙通訊
- BLE MTU 設為 512 bytes
- 時間戳記使用 Unix Timestamp（秒）
- JSON 使用 UTF-8 編碼

## 授權

MIT License
