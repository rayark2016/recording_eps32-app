// include/audio_config.h
// ESP32-S3 SD 卡錄音韌體設定（馬達實驗室用）
#pragma once
#include <Arduino.h>
#include "driver/gpio.h"

// ====== PDM 麥克風腳位 ======
#define PDM_CLK_PIN   GPIO_NUM_1     // CLK（已由最小化 PDM 測試驗證）
#define PDM_DATA_PIN  GPIO_NUM_41    // DATA（已由最小化 PDM 測試驗證）

// ====== SD 卡 SPI 腳位 ======
#define SD_MISO_PIN   GPIO_NUM_12
#define SD_SCK_PIN    GPIO_NUM_14
#define SD_MOSI_PIN   GPIO_NUM_15
#define SD_CS_PIN     GPIO_NUM_16

// ====== 音訊參數 ======
#define SAMPLE_RATE      16000
#define CHANNELS         1
#define BITS_PER_SAMPLE  16

// 每幀 20ms：16 kHz 時為 320 samples = 640 bytes
#define FRAME_MS         20
#define FRAME_SAMPLES    (SAMPLE_RATE * FRAME_MS / 1000)
#define FRAME_BYTES      (FRAME_SAMPLES * sizeof(int16_t))

// ====== 錄音參數 ======
#define MAX_RECORD_DURATION_SEC  180     // 最大錄音時長（秒）

// ====== 檔案管理 ======
#define RECORDINGS_DIR "/recordings"

// ====== SPI 配置 ======
#define SD_SPI_FREQ_MHZ 4

// ====== 已上架 Pico iOS App 的 BLE 相容協定 ======
#define BLE_DEVICE_NAME          "ESP32_Pico_Recorder"
#define BLE_MTU_SIZE             512
#define BLE_SERVICE_UUID         "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_RECORD_CTRL_UUID     "4fafc201-1fb5-459e-8fcc-c5c9c331914c"
#define BLE_SYSTEM_STATE_UUID    "4fafc201-1fb5-459e-8fcc-c5c9c331914d"
#define BLE_RECORD_INFO_UUID     "4fafc201-1fb5-459e-8fcc-c5c9c331914e"
#define BLE_USER_DATA_UUID       "4fafc201-1fb5-459e-8fcc-c5c9c331914f"
#define BLE_TIME_SYNC_UUID       "4fafc201-1fb5-459e-8fcc-c5c9c3319150"
#define BLE_CONFIRM_UUID         "4fafc201-1fb5-459e-8fcc-c5c9c3319151"
#define BLE_RECORD_LIST_UUID     "4fafc201-1fb5-459e-8fcc-c5c9c3319152"
#define BLE_RECORD_DATA_UUID     "4fafc201-1fb5-459e-8fcc-c5c9c3319153"
#define BLE_DEVICE_CONFIG_UUID   "4fafc201-1fb5-459e-8fcc-c5c9c3319154"

// Recorded into every WAV sidecar JSON to make SD-card exports traceable.
#define FIRMWARE_VERSION          "5.4.2"
