/// ble_service.dart
/// 藍牙 BLE 服務管理（基於參考專案格式）

import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BLEService {
  // BLE UUIDs (使用 Guid 格式，與參考專案一致)
  static final Guid serviceUuid = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  static final Guid recordCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914c");
  static final Guid statusCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914d");
  static final Guid recordInfoCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914e");
  static final Guid userDataCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914f");
  static final Guid timeSyncCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c3319150");
  static final Guid confirmCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c3319151");
  static final Guid recordListCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c3319152");
  static final Guid recordDataCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c3319153");
  static final Guid deviceConfigCharUuid =
      Guid("4fafc201-1fb5-459e-8fcc-c5c9c3319154");

  // BLE 連接相關
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? recordChar;
  BluetoothCharacteristic? statusChar;
  BluetoothCharacteristic? recordInfoChar;
  BluetoothCharacteristic? userDataChar;
  BluetoothCharacteristic? confirmChar;
  BluetoothCharacteristic? recordListChar;
  BluetoothCharacteristic? recordDataChar;
  BluetoothCharacteristic? timeSyncChar;
  BluetoothCharacteristic? deviceConfigChar;

  // 訂閱管理（防止累積）
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _statusCharSubscription;
  StreamSubscription? _recordInfoCharSubscription;
  StreamSubscription? _confirmCharSubscription;
  StreamSubscription? _recordListCharSubscription;
  StreamSubscription? _recordDataCharSubscription;

  // JSON 分段暫存 (key -> list of chunks)
  final Map<String, List<String>> _jsonChunks = {};
  String? _currentJsonKey;
  String? _lastConfirmMessage; // 去重檢查
  String? _lastConnectionError;
  int _connectionSession = 0;
  bool _connectionReady = false;
  int _nextRequestId = 0;

  int _newRequestId() {
    _nextRequestId = (_nextRequestId + 1) & 0x7fffffff;
    return _nextRequestId == 0 ? ++_nextRequestId : _nextRequestId;
  }

  List<int> _requestPacket(int command, int requestId) => [
        command,
        requestId & 0xff,
        (requestId >> 8) & 0xff,
        (requestId >> 16) & 0xff,
        (requestId >> 24) & 0xff,
      ];

  // Stream Controllers
  final _systemStatusController = StreamController<String>.broadcast();
  final _recordingInfoController = StreamController<String>.broadcast();
  final _confirmController = StreamController<Map<String, dynamic>>.broadcast();
  final _recordListController = StreamController<String>.broadcast();
  final _recordDataController = StreamController<String>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  // Streams
  Stream<String> get systemStatusStream => _systemStatusController.stream;
  Stream<String> get recordingInfoStream => _recordingInfoController.stream;
  Stream<Map<String, dynamic>> get confirmStream => _confirmController.stream;
  Stream<String> get recordListStream => _recordListController.stream;
  Stream<String> get recordDataStream => _recordDataController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;

  /// 是否已連接
  /// True only after discovery and all required characteristics are ready.
  /// A non-null device alone is not proof that the current BLE session works.
  bool get isConnected => _connectionReady;
  String? get lastConnectionError => _lastConnectionError;

  // A notification subscription failure must not discard an otherwise valid
  // BLE connection.  iOS can retain an older GATT cache after firmware changes;
  // keeping the session alive makes the precise failed characteristic visible.
  Future<bool> _enableNotifications(
      BluetoothCharacteristic characteristic, String label) async {
    try {
      await characteristic.setNotifyValue(true);
      print('[BLE] ✅ 已訂閱 $label');
      return true;
    } catch (e) {
      _lastConnectionError = '$label 通知訂閱失敗：$e';
      print('[BLE] ⚠️ $_lastConnectionError');
      return false;
    }
  }

  /// 掃描藍牙裝置
  Future<List<BluetoothDevice>> scanDevices(
      {Duration timeout = const Duration(seconds: 5)}) async {
    List<BluetoothDevice> devices = [];

    print('[BLE] 開始掃描裝置...');
    await FlutterBluePlus.startScan(timeout: timeout);

    // 監聽掃描結果
    await for (List<ScanResult> results in FlutterBluePlus.scanResults) {
      for (ScanResult result in results) {
        final name = result.device.platformName;
        final advName = result.advertisementData.advName;

        // 檢查 platformName 或 advName 是否包含 Pico 或 ESP32
        if ((name.isNotEmpty &&
                (name.contains('Pico') || name.contains('ESP32'))) ||
            (advName.isNotEmpty &&
                (advName.contains('Pico') || advName.contains('ESP32')))) {
          if (!devices.contains(result.device)) {
            devices.add(result.device);
            print('[BLE] 找到裝置: $name (advName: $advName)');
          }
        }
      }
    }

    await FlutterBluePlus.stopScan();
    print('[BLE] 掃描結束，共找到 ${devices.length} 個裝置');
    return devices;
  }

  Future<List<BluetoothService>> _discoverServicesWithOneRetry(
      BluetoothDevice device) async {
    try {
      return await device.discoverServices();
    } catch (firstError) {
      // A recorder that has just powered up can accept a link before its
      // GATT server responds to discovery. Reset this one connection and try
      // once more; do not leave the device silently connected but unusable.
      print('[BLE] 第一次服務探索失敗，將自動重連一次：$firstError');
      try {
        await device.disconnect();
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 2));
      await device.connect(timeout: const Duration(seconds: 15));
      try {
        await device.requestMtu(512);
      } catch (_) {
        // iOS may keep its default MTU; discovery is still valid.
      }
      return await device.discoverServices();
    }
  }

  /// 連接裝置
  Future<bool> connectToDevice(BluetoothDevice device) async {
    // Retire any previous listener before a new session starts. A late
    // disconnection event from that listener must never clear this session.
    await disconnect();
    final session = ++_connectionSession;
    try {
      _lastConnectionError = null;
      print('[BLE] 開始連接裝置: ${device.platformName}');
      connectedDevice = device;

      // 連接裝置 (flutter_blue_plus 2.x 不需要 license 參數)
      await device.connect(timeout: const Duration(seconds: 15));
      if (session != _connectionSession) return false;

      print('[BLE] 裝置已連接，正在請求 MTU...');

      // 請求最大 MTU 以提升傳輸速度
      try {
        final mtu = await device.requestMtu(512);
        print('[BLE] ✅ MTU 協商成功: $mtu bytes');
      } catch (e) {
        print('[BLE] ⚠️ MTU 協商失敗: $e (將使用預設值)');
      }

      print('[BLE] 開始發現服務...');

      // 發現服務
      List<BluetoothService> services =
          await _discoverServicesWithOneRetry(device);
      print('[BLE] 找到 ${services.length} 個服務');

      // 尋找我們的服務
      BluetoothService? targetService;
      for (var service in services) {
        print('[BLE] Service UUID: ${service.uuid}');
        if (service.uuid == serviceUuid) {
          targetService = service;
          print('[BLE] ✅ 找到目標服務');
          break;
        }
      }

      if (targetService == null) {
        print('[BLE] ❌ 未找到目標服務');
        await disconnect();
        return false;
      }

      // 設定所有特徵
      for (var char in targetService.characteristics) {
        print('[BLE] Characteristic UUID: ${char.uuid}');

        if (char.uuid == recordCharUuid) {
          recordChar = char;
          print('[BLE] ✅ 找到錄音控制 Characteristic');
        } else if (char.uuid == statusCharUuid) {
          statusChar = char;
          print('[BLE] ✅ 找到系統狀態 Characteristic');
          // 訂閱系統狀態通知
          if (!await _enableNotifications(char, '系統狀態')) {
            await disconnect();
            return false;
          }
          _statusCharSubscription = char.lastValueStream.listen((value) {
            if (value.isNotEmpty) {
              // Firmware status messages are UTF-8 Chinese text. Decoding
              // byte-by-byte created mojibake such as "éé³..." and
              // prevented the UI state machine from seeing "錄音中".
              final status = utf8.decode(value, allowMalformed: true);
              print('[BLE] 收到系統狀態: $status');
              _systemStatusController.add(status);
            }
          });
        } else if (char.uuid == recordInfoCharUuid) {
          recordInfoChar = char;
          print('[BLE] ✅ 找到錄音資訊 Characteristic');
          // 訂閱錄音資訊通知（JSON 格式，可能分段）
          if (!await _enableNotifications(char, '錄音資訊')) {
            await disconnect();
            return false;
          }
          _recordInfoCharSubscription = char.lastValueStream.listen((value) {
            if (value.isNotEmpty) {
              _handleRecordInfoChunk(value);
            }
          });
        } else if (char.uuid == userDataCharUuid) {
          userDataChar = char;
          print('[BLE] ✅ 找到使用者資料 Characteristic');
        } else if (char.uuid == confirmCharUuid) {
          confirmChar = char;
          print('[BLE] ✅ 找到確認訊息 Characteristic');
          // 訂閱確認訊息通知
          if (!await _enableNotifications(char, '確認訊息')) {
            await disconnect();
            return false;
          }
          _confirmCharSubscription = char.lastValueStream.listen((value) {
            if (value.isNotEmpty) {
              final confirmMsg = utf8.decode(value, allowMalformed: true);

              // 去重檢查：如果與上次訊息相同，忽略
              if (_lastConfirmMessage == confirmMsg) {
                print('[BLE] 忽略重複的確認訊息: $confirmMsg');
                return;
              }

              _lastConfirmMessage = confirmMsg;
              print('[BLE] 收到確認訊息: $confirmMsg');

              // 嘗試解析 JSON，失敗則作為純文字處理
              try {
                final Map<String, dynamic> confirmData = jsonDecode(confirmMsg);
                _confirmController.add(confirmData);
              } catch (e) {
                // 純文字訊息，包裝成 JSON 格式
                _confirmController.add({'message': confirmMsg});
                print('[BLE] ✅ 確認訊息（純文字）: $confirmMsg');
              }
            }
          });
        } else if (char.uuid == recordListCharUuid) {
          recordListChar = char;
          print('[BLE] ✅ 找到記錄列表 Characteristic');
          // 訂閱記錄列表通知（JSON 格式，可能分段）
          if (!await _enableNotifications(char, '記錄列表')) {
            await disconnect();
            return false;
          }
          _recordListCharSubscription = char.lastValueStream.listen((value) {
            if (value.isNotEmpty) {
              _handleRecordListChunk(value);
            }
          });
        } else if (char.uuid == recordDataCharUuid) {
          recordDataChar = char;
          print('[BLE] ✅ 找到記錄內容 Characteristic');
          // 訂閱記錄內容通知（JSON 格式，可能分段）
          if (!await _enableNotifications(char, '記錄內容')) {
            await disconnect();
            return false;
          }
          _recordDataCharSubscription = char.lastValueStream.listen((value) {
            if (value.isNotEmpty) {
              _handleRecordDataChunk(value);
            }
          });
        } else if (char.uuid == timeSyncCharUuid) {
          timeSyncChar = char;
          print('[BLE] ✅ 找到時間同步 Characteristic');
        } else if (char.uuid == deviceConfigCharUuid) {
          deviceConfigChar = char;
          print('[BLE] ✅ 找到唯讀設備身分 Characteristic');
        }
      }

      // 檢查是否所有必要的 Characteristics 都找到了
      if (recordChar == null ||
          statusChar == null ||
          recordInfoChar == null ||
          userDataChar == null ||
          confirmChar == null ||
          recordDataChar == null) {
        print('[BLE] ❌ 缺少必要的 Characteristics');
        await disconnect();
        return false;
      }

      // 監聽連接狀態
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          print('[BLE] 檢測到斷線，清理資源...');
          _handleDisconnection(session: session);
        }
      });

      _connectionReady = true;
      _connectionController.add(true);
      print('[BLE] ✅ 連接完成，所有功能已就緒');

      // 等待一下再同步時間（確保 BLE 連接穩定）
      await Future.delayed(Duration(milliseconds: 500));
      print('[BLE] 🕐 準備同步時間...');
      final syncResult = await syncTime();
      if (syncResult) {
        print('[BLE] ✅ 時間同步請求已發送');
      } else {
        print('[BLE] ⚠️ 時間同步請求失敗');
      }

      return true;
    } catch (e) {
      _lastConnectionError = e.toString();
      print('[BLE] ❌ 連接錯誤: $e');
      if (session == _connectionSession) await disconnect();
      return false;
    }
  }

  /// 開始錄音
  Future<int?> startRecording() async {
    if (recordChar == null) return null;

    try {
      final requestId = _newRequestId();
      await recordChar!.write(_requestPacket(0x01, requestId));
      print('[BLE] 錄音指令已發送: START($requestId)');
      return requestId;
    } catch (e) {
      print('[BLE] 開始錄音錯誤: $e');
      return null;
    }
  }

  /// Reads immutable ESP32 hardware UID and the assigned human-readable code.
  Future<Map<String, dynamic>?> readDeviceInfo() async {
    if (deviceConfigChar == null) return null;
    try {
      final bytes = await deviceConfigChar!.read();
      return jsonDecode(utf8.decode(bytes, allowMalformed: true))
          as Map<String, dynamic>;
    } catch (e) {
      print('[BLE] 讀取設備身分失敗: $e');
      return null;
    }
  }

  /// Requests the recorder's current SD mount state. 0x02 is reserved for
  /// this query and does not start or stop recording.
  Future<bool> checkStorage(int requestId) async {
    if (recordChar == null) return false;
    try {
      await recordChar!.write([0x02, requestId & 0xff]);
      return true;
    } catch (e) {
      print('[BLE] SD 狀態查詢錯誤: $e');
      return false;
    }
  }

  /// 停止錄音
  Future<int?> stopRecording() async {
    if (recordChar == null) return null;

    try {
      final requestId = _newRequestId();
      await recordChar!.write(_requestPacket(0x00, requestId));
      print('[BLE] 錄音指令已發送: STOP($requestId)');
      return requestId;
    } catch (e) {
      print('[BLE] 停止錄音錯誤: $e');
      return null;
    }
  }

  Future<int?> getRecorderStatus() async {
    if (recordChar == null) return null;
    try {
      final requestId = _newRequestId();
      await recordChar!.write(_requestPacket(0x03, requestId));
      return requestId;
    } catch (e) {
      print('[BLE] 狀態查詢錯誤: $e');
      return null;
    }
  }

  /// 處理錄音資訊 JSON 分段接收
  void _handleRecordInfoChunk(List<int> value) {
    final chunk = utf8.decode(value, allowMalformed: true);
    print('[BLE] 收到錄音資訊分段: ${chunk.length} bytes');

    // 解析分段格式：index/total:data
    final colonIndex = chunk.indexOf(':');
    if (colonIndex == -1) {
      print('[BLE] ❌ 無效的分段格式，找不到冒號分隔符');
      print('[BLE] 原始資料: $chunk');
      return;
    }

    final header = chunk.substring(0, colonIndex);
    final data = chunk.substring(colonIndex + 1);
    final parts = header.split('/');

    print('[BLE] 分段標頭: $header, 資料長度: ${data.length}');

    if (parts.length != 2) {
      print('[BLE] ❌ 無效的分段標頭，parts.length = ${parts.length}');
      print('[BLE] parts: $parts');
      return;
    }

    final currentIndex = int.tryParse(parts[0]);
    final totalChunks = int.tryParse(parts[1]);

    if (currentIndex == null || totalChunks == null) {
      print(
          '[BLE] ❌ 無法解析分段索引，currentIndex=$currentIndex, totalChunks=$totalChunks');
      print('[BLE] parts[0]="${parts[0]}", parts[1]="${parts[1]}"');
      return;
    }

    print('[BLE] 分段 ${currentIndex + 1}/$totalChunks');

    // 初始化或添加分段
    final key = 'recordInfo';
    if (currentIndex == 0) {
      _jsonChunks[key] = [];
      _currentJsonKey = key;
    }

    if (_jsonChunks[key] != null) {
      _jsonChunks[key]!.add(data);

      // 檢查是否接收完整
      if (_jsonChunks[key]!.length == totalChunks) {
        final completeJson = _jsonChunks[key]!.join('');
        print('[BLE] ✅ 完整 JSON 接收完成 (${completeJson.length} bytes)');

        try {
          _recordingInfoController.add(completeJson);
          print('[BLE] 錄音資訊已發送至 Stream');
        } catch (e) {
          print('[BLE] ❌ JSON 處理錯誤: $e');
        }

        // 清除暫存
        _jsonChunks.remove(key);
        _currentJsonKey = null;
      }
    }
  }

  /// 傳送使用者資料到 ESP32
  Future<bool> sendUserData(
      String wavFilename, Map<String, dynamic> userData) async {
    if (userDataChar == null) {
      print('[BLE] ❌ userDataChar 未初始化');
      return false;
    }

    try {
      final recordId = wavFilename.endsWith('.wav')
          ? wavFilename.substring(0, wavFilename.length - 4)
          : wavFilename;
      final bytes = utf8.encode(jsonEncode(userData));
      if (bytes.isEmpty || bytes.length > 4096) return false;
      final transactionId = _newRequestId();
      final begin = utf8.encode(jsonEncode({
        'record_id': recordId,
        'transaction_id': transactionId,
        'total_bytes': bytes.length,
      }));
      await userDataChar!.write([0xB0, ...begin], withoutResponse: false);
      const chunkSize = 160;
      var sequence = 0;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length);
        await userDataChar!.write([
          0xB1,
          sequence & 0xff,
          (sequence >> 8) & 0xff,
          ...bytes.sublist(offset, end),
        ], withoutResponse: false);
        sequence++;
      }
      final commit = utf8.encode(jsonEncode({'transaction_id': transactionId}));
      await userDataChar!.write([0xB2, ...commit], withoutResponse: false);

      print('[BLE] ✅ 使用者資料分段傳送完成 (${bytes.length} bytes)');
      return true;
    } catch (e) {
      print('[BLE] ❌ 傳送使用者資料錯誤: $e');
      return false;
    }
  }

  /// 同步時間到 ESP32
  Future<bool> syncTime() async {
    if (timeSyncChar == null) {
      print('[BLE] ❌ timeSyncChar 未初始化');
      return false;
    }

    try {
      // 取得當前 Unix timestamp (秒)
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      print('[BLE] 同步時間: $timestamp (${DateTime.now()})');

      // 轉換為 4 bytes (uint32_t, little-endian)
      final bytes = [
        timestamp & 0xFF,
        (timestamp >> 8) & 0xFF,
        (timestamp >> 16) & 0xFF,
        (timestamp >> 24) & 0xFF,
      ];

      // 寫入時間資料
      await timeSyncChar!.write(bytes, withoutResponse: false);

      print('[BLE] ✅ 時間同步完成');
      return true;
    } catch (e) {
      print('[BLE] ❌ 時間同步錯誤: $e');
      return false;
    }
  }

  /// 請求記錄列表（支援分頁）
  Future<bool> requestRecordList({int page = 0, int pageSize = 20}) async {
    if (recordListChar == null) {
      print('[BLE] ❌ recordListChar 未初始化');
      return false;
    }

    try {
      // 建立 JSON 命令
      final command = {
        'cmd': 'LIST',
        'page': page,
        'page_size': pageSize,
      };
      final jsonString = jsonEncode(command);

      print('[BLE] 請求記錄列表 (page: $page, pageSize: $pageSize)...');

      // 發送 JSON 命令
      await recordListChar!
          .write(utf8.encode(jsonString), withoutResponse: false);
      print('[BLE] ✅ 記錄列表請求已發送');
      return true;
    } catch (e) {
      print('[BLE] ❌ 請求記錄列表錯誤: $e');
      return false;
    }
  }

  /// 請求單筆記錄內容
  Future<bool> requestRecordData(String filename) async {
    if (recordDataChar == null) {
      print('[BLE] ❌ recordDataChar 未初始化');
      return false;
    }

    try {
      print('[BLE] 請求記錄 JSON: $filename');
      final bytes = utf8.encode(jsonEncode({
        'cmd': 'READ_METADATA',
        'filename': filename,
      }));
      await recordDataChar!.write(bytes, withoutResponse: false);
      print('[BLE] ✅ 記錄內容請求已發送');
      return true;
    } catch (e) {
      print('[BLE] ❌ 請求記錄內容錯誤: $e');
      return false;
    }
  }

  /// 處理記錄列表分段資料
  void _handleRecordListChunk(List<int> value) {
    final data = utf8.decode(value, allowMalformed: true);
    print('[BLE] 收到記錄列表分段: ${data.length} bytes');

    // 忽略命令 echo（檢查是否包含 "cmd" 字段）
    if (data.contains('"cmd"')) {
      print('[BLE] ⚠️  忽略命令 echo');
      return;
    }

    // 檢查是否有分段標記（格式：index/total:data）
    if (data.contains(':') && data.contains('/')) {
      int colonIndex = data.indexOf(':');
      String header = data.substring(0, colonIndex);
      String content = data.substring(colonIndex + 1);

      List<String> parts = header.split('/');
      if (parts.length == 2) {
        int index = int.parse(parts[0]);
        int total = int.parse(parts[1]);

        // 初始化分段暫存
        if (!_jsonChunks.containsKey('recordList')) {
          _jsonChunks['recordList'] = List.filled(total, '');
          print('[BLE] 初始化分段暫存，預期共 $total 段');
        }

        // 儲存分段
        _jsonChunks['recordList']![index] = content;

        print('[BLE] 收到記錄列表分段 ${index + 1}/$total (${content.length} bytes)');

        // 檢查是否收集完所有分段
        if (_jsonChunks['recordList']!.every((chunk) => chunk.isNotEmpty)) {
          String completeJson = _jsonChunks['recordList']!.join('');
          print('[BLE] ✅ 記錄列表接收完成 (${completeJson.length} bytes)');

          // 發送到 Stream
          _recordListController.add(completeJson);

          // 清除暫存
          _jsonChunks.remove('recordList');
        }
      }
    } else {
      // 沒有分段標記，直接發送
      print('[BLE] ✅ 記錄列表接收完成（單段）');
      _recordListController.add(data);
    }
  }

  /// 處理記錄內容分段資料（支援 JSON 和二進制 WAV）
  final Map<String, List<int>> _wavChunks = {};
  Map<String, dynamic>? _currentWavHeader;
  int _nextWavSequence = 0;
  bool _usesSequencedWavTransfer = false;

  Future<void> _acknowledgeWavPacket(int sequence) async {
    if (recordDataChar == null) return;
    try {
      await recordDataChar!.write(
        [0xA1, sequence & 0xFF, (sequence >> 8) & 0xFF],
        withoutResponse: false,
      );
    } catch (error) {
      print('[BLE] WAV ACK 寫入失敗（sequence=$sequence）: $error');
    }
  }

  void _handleRecordDataChunk(List<int> value) {
    // 嘗試解析為文字（JSON header 或分段標記）
    String data = '';
    try {
      data = utf8.decode(value, allowMalformed: true);
    } catch (e) {
      // 如果無法解碼為文字，當作二進制資料處理
      data = '';
    }

    print('[BLE] 收到記錄內容資料: ${value.length} bytes');

    // 檢查是否為 JSON header（第一次傳輸）
    if (data.isNotEmpty && data.contains('{') && data.contains('"type"')) {
      try {
        final jsonData = jsonDecode(data);
        if (jsonData['type'] == 'wav' || jsonData['type'] == 'wav_manifest') {
          _currentWavHeader = jsonData;
          _wavChunks['current'] = [];
          _nextWavSequence = 0;
          _usesSequencedWavTransfer = jsonData['type'] == 'wav_manifest';
          print('[BLE] 📥 開始接收 WAV 檔案: ${jsonData['filename']}');
          print(
              '[BLE]    大小: ${jsonData['filesize']} bytes, 分段: ${jsonData['chunks']}');
          if (_usesSequencedWavTransfer) {
            // 0xFFFF acknowledges that the transfer manifest arrived before
            // the firmware begins sending binary packets.
            unawaited(_acknowledgeWavPacket(0xFFFF));
          }
          return;
        }
      } catch (e) {
        print('[BLE] ⚠️  JSON header 解析失敗: $e');
      }
    }

    // 如果正在接收 WAV 檔案，累積二進制資料
    if (_currentWavHeader != null && _wavChunks.containsKey('current')) {
      List<int> payload = value;
      if (_usesSequencedWavTransfer) {
        if (value.length < 3) {
          print('[BLE] ❌ 無效的 WAV 封包：缺少 sequence 或 payload');
          return;
        }
        final sequence = value[0] | (value[1] << 8);
        if (sequence < _nextWavSequence) {
          // The firmware may resend after an ACK race. Confirm the duplicate
          // without adding it twice.
          unawaited(_acknowledgeWavPacket(sequence));
          return;
        }
        if (sequence != _nextWavSequence) {
          print('[BLE] ❌ WAV sequence 不連續：預期 $_nextWavSequence，收到 $sequence');
          return;
        }
        payload = value.sublist(2);
        _nextWavSequence++;
        unawaited(_acknowledgeWavPacket(sequence));
      }
      _wavChunks['current']!.addAll(payload);
      final received = _wavChunks['current']!.length;
      final total = _currentWavHeader!['filesize'] as int;

      print(
          '[BLE] WAV 進度: $received / $total bytes (${(received * 100 / total).toStringAsFixed(1)}%)');

      // 檢查是否接收完成
      if (received >= total) {
        print('[BLE] ✅ WAV 檔案接收完成');

        // 組合完整資訊並發送
        final result = {
          'type': 'wav',
          'filename': _currentWavHeader!['filename'],
          'filesize': total,
          // A final notification may contain bytes after the declared WAV
          // payload. Never silently save those extra bytes as part of WAV.
          'data': _wavChunks['current']!.sublist(0, total),
        };

        _recordDataController.add(jsonEncode(result));

        // 清除暫存
        _currentWavHeader = null;
        _wavChunks.remove('current');
        _usesSequencedWavTransfer = false;
      }
      return;
    }

    // 舊的 JSON 分段處理邏輯（向後兼容）
    if (data.isEmpty) {
      print('[BLE] ⚠️  收到空資料或二進制資料但無 header');
      return;
    }

    // 忽略檔名 echo
    if (!data.contains('{') && !data.contains(':')) {
      print('[BLE] ⚠️  忽略檔名 echo');
      return;
    }

    // 忽略錯誤訊息
    if (data.contains('"error"')) {
      print('[BLE] ⚠️  忽略錯誤訊息');
      return;
    }

    // 檢查是否有分段標記（格式：index/total:data）
    if (data.contains(':') && data.contains('/')) {
      int colonIndex = data.indexOf(':');
      String header = data.substring(0, colonIndex);
      String content = data.substring(colonIndex + 1);

      List<String> parts = header.split('/');
      if (parts.length == 2) {
        int index = int.parse(parts[0]);
        int total = int.parse(parts[1]);

        // 初始化分段暫存
        if (!_jsonChunks.containsKey('recordData')) {
          _jsonChunks['recordData'] = List.filled(total, '');
        }

        // 儲存分段
        _jsonChunks['recordData']![index] = content;

        print('[BLE] 收到記錄內容分段 ${index + 1}/$total');

        // 檢查是否收集完所有分段
        if (_jsonChunks['recordData']!.every((chunk) => chunk.isNotEmpty)) {
          String completeJson = _jsonChunks['recordData']!.join('');
          print('[BLE] ✅ 記錄內容接收完成 (${completeJson.length} bytes)');

          // 發送到 Stream
          _recordDataController.add(completeJson);

          // 清除暫存
          _jsonChunks.remove('recordData');
        }
      }
    } else {
      // 沒有分段標記，直接發送
      print('[BLE] ✅ 記錄內容接收完成（單段）');
      _recordDataController.add(data);
    }
  }

  /// 斷開連接
  Future<void> disconnect() async {
    try {
      if (connectedDevice != null) {
        await connectedDevice!.disconnect();
      }
    } catch (e) {
      print('[BLE] 斷開連接錯誤: $e');
    } finally {
      _handleDisconnection();
    }
  }

  /// 處理斷線事件
  void _handleDisconnection({int? session}) {
    // Ignore a late callback from a connection that has already been replaced.
    if (session != null && session != _connectionSession) return;
    final hadActiveSession = connectedDevice != null || _connectionReady;
    _connectionSession++;
    print('[BLE] 清理連接資源...');

    // 取消所有 BLE characteristic 的監聽器訂閱
    _connectionStateSubscription?.cancel();
    _statusCharSubscription?.cancel();
    _recordInfoCharSubscription?.cancel();
    _confirmCharSubscription?.cancel();
    _recordListCharSubscription?.cancel();
    _recordDataCharSubscription?.cancel();

    // 清空訂閱引用
    _connectionStateSubscription = null;
    _statusCharSubscription = null;
    _recordInfoCharSubscription = null;
    _confirmCharSubscription = null;
    _recordListCharSubscription = null;
    _recordDataCharSubscription = null;

    // 清空 characteristic 引用
    connectedDevice = null;
    recordChar = null;
    statusChar = null;
    recordInfoChar = null;
    userDataChar = null;
    confirmChar = null;
    recordListChar = null;
    recordDataChar = null;
    timeSyncChar = null;
    deviceConfigChar = null;

    // 清空暫存資料
    _jsonChunks.clear();
    _currentJsonKey = null;

    // 清除最後確認訊息記錄
    _lastConfirmMessage = null;

    // 通知連接狀態改變
    _connectionReady = false;
    if (hadActiveSession) _connectionController.add(false);

    print('[BLE] ✅ 連接資源已清理');
  }

  /// 釋放資源
  void dispose() {
    print('[BLE] 釋放 BLEService 資源...');

    // 取消所有訂閱
    _connectionStateSubscription?.cancel();
    _statusCharSubscription?.cancel();
    _recordInfoCharSubscription?.cancel();
    _confirmCharSubscription?.cancel();
    _recordListCharSubscription?.cancel();
    _recordDataCharSubscription?.cancel();

    // 關閉所有 StreamController
    _systemStatusController.close();
    _recordingInfoController.close();
    _confirmController.close();
    _recordListController.close();
    _recordDataController.close();
    _connectionController.close();

    print('[BLE] ✅ BLEService 資源已釋放');
  }
}
