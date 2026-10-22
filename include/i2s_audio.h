// include/i2s_audio.h
#pragma once
#include <Arduino.h>

// ESP-IDF 5 的 PDM RX API；設定須與已驗證的最小化測試一致。
bool   i2s_up();
size_t i2s_read_samples(void* buf, size_t size_bytes);
