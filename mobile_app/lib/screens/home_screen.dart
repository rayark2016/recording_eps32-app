/// home_screen.dart
/// 主畫面

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../services/ble_service.dart';
import '../services/wav_validator.dart';
import '../models/recording_data.dart';
import '../models/recording_session_state.dart';
import '../widgets/connection_status_card.dart';
import '../widgets/device_scanner_view.dart';
import '../widgets/recording_controls_view.dart';
import 'history_screen.dart';
import 'recording_form_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BLEService _bleService = BLEService();

  bool _isScanning = false;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  RecordingSessionState _recordingState = const RecordingSessionState.idle();
  // A separate guard protects the command path even if a delayed UI rebuild
  // briefly shows an old button state.
  bool _recordingWorkflowLocked = false;
  bool _isBleConnected = false;
  bool _isConnecting = false;
  bool _isCheckingStorage = false;
  bool? _isStorageReady;
  String _storageStatus = '正在確認 SD 卡…';
  String _deviceCode = '';
  String _hardwareUid = '';
  bool _isProvisionLocked = false;
  List<ScanResult> _scanResults = [];
  String _systemStatus = '未連接';
  String _lastFilename = '';
  RecordingInfo? _currentRecordingInfo;
  Completer<String?>? _metadataSaveCompleter;
  Completer<bool>? _storageCheckCompleter;
  int? _activeStorageRequestId;
  int _nextStorageRequestId = 0;

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<String>? _systemStatusSubscription;
  StreamSubscription<String>? _recordingInfoSubscription;
  StreamSubscription<String>? _recordDataSubscription;
  StreamSubscription<Map<String, dynamic>>? _confirmSubscription;
  StreamSubscription<bool>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    _setupListeners();
    _watchBluetoothAdapter();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _systemStatusSubscription?.cancel();
    _recordingInfoSubscription?.cancel();
    _recordDataSubscription?.cancel();
    _confirmSubscription?.cancel();
    _connectionSubscription?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  void _watchBluetoothAdapter() {
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() {
        _adapterState = state;
        // A scan is no longer valid once CoreBluetooth leaves the ready state.
        if (state != BluetoothAdapterState.on) {
          _isScanning = false;
        }
      });
    });
  }

  String get _bluetoothStatus {
    switch (_adapterState) {
      case BluetoothAdapterState.on:
        return '藍牙已就緒';
      case BluetoothAdapterState.unknown:
        return '正在初始化藍牙…';
      case BluetoothAdapterState.turningOn:
        return '正在開啟藍牙…';
      case BluetoothAdapterState.turningOff:
        return '藍牙正在關閉…';
      case BluetoothAdapterState.off:
        return '請在 iPhone 設定中開啟藍牙';
      case BluetoothAdapterState.unauthorized:
        return '請在設定中允許此 App 使用藍牙';
      case BluetoothAdapterState.unavailable:
        return '此裝置無法使用藍牙';
    }
  }

  void _setupListeners() {
    // 監聽系統狀態
    _systemStatusSubscription = _bleService.systemStatusStream.listen((status) {
      if (mounted && _isBleConnected) {
        setState(() {
          _systemStatus = status;
          // Firmware V5 currently emits the Chinese legacy text. Future
          // firmware may emit the ASCII state names from the protocol docs.
          if (status.contains('錄音中') || status.contains('RECORDING')) {
            if (_recordingState.phase == RecordingPhase.starting) {
              _recordingState = RecordingSessionState(
                phase: RecordingPhase.recording,
                sessionId: _recordingState.sessionId,
                detail: '錄音器已確認正在錄音',
              );
            }
          } else if (status.startsWith('FAILED:')) {
            if (status.startsWith('FAILED:SD_')) {
              _isStorageReady = false;
              _storageStatus = 'SD 卡不可用，無法開始錄音';
            }
            _setRecordingFailure('RECORDER_FAILED', status);
          }
        });
      }
    });

    // 監聽錄音完成資訊
    _recordingInfoSubscription =
        _bleService.recordingInfoStream.listen((jsonStr) {
      if (mounted) {
        print('[HomeScreen] 收到錄音資訊 JSON: $jsonStr');
        try {
          // 解析 JSON
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;

          // 將 recording_duration_sec 轉換為整數
          if (json['recording_duration_sec'] != null) {
            json['recording_duration_sec'] =
                (json['recording_duration_sec'] as num).round();
          }

          // 建立 RecordingInfo（從 AutoData 建立）
          final autoData = AutoData.fromJson(json);
          final recordingInfo = RecordingInfo(
            autoData: autoData,
            userData: null,
            status: 'pending',
          );

          setState(() {
            _currentRecordingInfo = recordingInfo;
            _lastFilename = recordingInfo.autoData.wavFilename;
            _recordingState = RecordingSessionState(
              phase: RecordingPhase.saved,
              sessionId: _recordingState.sessionId,
              filename: recordingInfo.autoData.wavFilename,
              detail: 'WAV 已安全儲存在錄音器 SD 卡',
            );
          });

          print('[HomeScreen] 📝 WAV 已留在 SD 卡，顯示使用者表單。');
          unawaited(_openRecordingForm(recordingInfo));
        } catch (e) {
          print('[HomeScreen] 解析錄音資訊錯誤: $e');
          _showMessage('❌ 錄音資訊解析失敗: $e', isError: true);
        }
      }
    });

    // 監聽 WAV 檔案接收
    _recordDataSubscription =
        _bleService.recordDataStream.listen((jsonStr) async {
      if (mounted) {
        print('[HomeScreen] 收到記錄資料: ${jsonStr.length} bytes');
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;

          if (json['type'] == 'wav') {
            final filename = json['filename'] as String;
            final data = (json['data'] as List<dynamic>).cast<int>();
            final expectedSize = json['filesize'] as int?;

            print(
                '[HomeScreen] 📥 接收 WAV 檔案: $filename (${data.length} bytes)');

            if (_currentRecordingInfo == null ||
                _currentRecordingInfo!.autoData.wavFilename != filename) {
              _setRecordingFailure('UNEXPECTED_FILE', '收到的 WAV 與目前錄音工作階段不相符');
              return;
            }

            // Validate before a file becomes visible in the app documents dir.
            final savedPath =
                await _saveWavFile(filename, data, expectedSize: expectedSize);
            if (savedPath != null) {
              print('[HomeScreen] ✅ WAV 已暫存至: $savedPath');
              _showMessage('✅ 音檔已下載');

              setState(() {
                _recordingState = RecordingSessionState(
                  phase: RecordingPhase.saved,
                  sessionId: _recordingState.sessionId,
                  filename: filename,
                  detail: 'WAV 已完成格式與長度驗證',
                );
              });

              // 立即顯示使用者輸入表單
              if (_currentRecordingInfo != null &&
                  _currentRecordingInfo!.autoData.wavFilename == filename) {
                print('[HomeScreen] 📝 顯示使用者輸入表單');
                unawaited(_openRecordingForm(_currentRecordingInfo!));
              }
            } else {
              print('[HomeScreen] ❌ WAV 儲存失敗');
              _setRecordingFailure('WAV_VALIDATION_FAILED', 'WAV 格式、長度或寫入驗證失敗');
              _showMessage('❌ 音檔儲存失敗', isError: true);
            }
          }
        } catch (e) {
          print('[HomeScreen] 處理記錄資料錯誤: $e');
          _showMessage('❌ 處理錄音資料失敗: $e', isError: true);
        }
      }
    });

    // 監聽確認訊息
    _confirmSubscription = _bleService.confirmStream.listen((message) {
      if (!mounted) return;

      final status = message['status'] as String? ?? '';
      final operation = message['operation'] as String? ?? '';
      final filename = message['filename'] as String? ?? '';
      final messageText = message['message'] as String? ?? '';

      // 忽略時間同步訊息
      if (messageText.contains('Time')) return;

      if (operation == 'wav_saved') {
        // The form page already shows the WAV storage state. Do not duplicate
        // it as a bottom snackbar.
        return;
      }

      if (operation == 'recorder_status') {
        final recorderState = message['state'] as String? ?? '';
        if (recorderState == 'recording' &&
            _recordingState.phase == RecordingPhase.starting) {
          setState(() {
            _recordingState = RecordingSessionState(
              phase: RecordingPhase.recording,
              sessionId: _recordingState.sessionId,
              filename: message['filename'] as String?,
              detail: '已由錄音器狀態確認正在錄音',
            );
          });
        } else if (recorderState == 'idle' &&
            _recordingState.phase == RecordingPhase.starting) {
          _setRecordingFailure('START_UNCONFIRMED', '錄音器未確認開始錄音');
        }
        return;
      }

      if (operation == 'storage_status') {
        final responseRequestId = (message['request_id'] as num?)?.toInt();
        // Ignore a delayed answer to an earlier query. Firmware V5.1 always
        // includes this ID, so an answer can only unlock its own request.
        if (responseRequestId == null ||
            responseRequestId != _activeStorageRequestId) {
          return;
        }
        final ready = message['sd'] == 'ready' && status == 'success';
        setState(() {
          _isCheckingStorage = false;
          _isStorageReady = ready;
          _storageStatus = ready ? 'SD 卡已連接' : '未偵測到 SD 卡：請關機後插卡再重新開機';
        });
        if (_storageCheckCompleter != null &&
            !_storageCheckCompleter!.isCompleted) {
          _storageCheckCompleter!.complete(ready);
        }
        return;
      }

      if (operation == 'metadata_saved') {
        final isExpectedFile =
            filename.isEmpty || filename == _recordingState.filename;
        if (!isExpectedFile ||
            _recordingState.phase != RecordingPhase.savingMetadata) {
          return;
        }
        if (status == 'success') {
          _metadataSaveCompleter?.complete(null);
        } else {
          _metadataSaveCompleter
              ?.complete(messageText.isEmpty ? '未知錯誤' : messageText);
        }
      }
    });

    // 監聽連接狀態
    _connectionSubscription = _bleService.connectionStream.listen((connected) {
      if (!mounted) return;
      if (connected) {
        setState(() {
          // A completed connection always begins a new recorder session.
          // Never carry the previous session's BLE_DISCONNECTED failure into
          // a healthy reconnection.
          _isBleConnected = true;
          _isConnecting = false;
          _systemStatus = '已連接';
          _recordingWorkflowLocked = false;
          _recordingState = const RecordingSessionState.idle();
          _isCheckingStorage = false;
          _isStorageReady = null;
          _storageStatus = '正在確認 SD 卡…';
          _deviceCode = '';
          _hardwareUid = '';
          _isProvisionLocked = false;
          _scanResults.clear();
        });
      } else {
        _applyDisconnectedState();
      }
    });
  }

  void _applyDisconnectedState() {
    if (_storageCheckCompleter != null &&
        !_storageCheckCompleter!.isCompleted) {
      _storageCheckCompleter!.complete(false);
    }
    _storageCheckCompleter = null;
    _activeStorageRequestId = null;
    setState(() {
      _isBleConnected = false;
      _isConnecting = false;
      _systemStatus = '已斷線';
      _recordingWorkflowLocked = false;
      _recordingState = const RecordingSessionState(
        phase: RecordingPhase.failed,
        errorCode: 'BLE_DISCONNECTED',
        detail: 'BLE 已斷線；本次錄音未確認完成',
      );
      _isCheckingStorage = false;
      _isStorageReady = null;
      _storageStatus = 'SD 卡狀態未知';
      _deviceCode = '';
      _hardwareUid = '';
      _isProvisionLocked = false;
      _scanResults.clear();
    });
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  Future<void> _startScan() async {
    // Both UI state and this guard protect against rapid repeated taps.
    if (_isScanning) return;
    if (_adapterState != BluetoothAdapterState.on) {
      _showMessage(_bluetoothStatus, isError: true);
      return;
    }

    print('[HomeScreen] ========== 開始掃描流程 ==========');

    setState(() {
      _isScanning = true;
      _scanResults.clear();
    });

    try {
      // Confirm the adapter is still ready immediately before starting the
      // platform scan. This closes the initialization/tap race on iOS.
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first;

      // 取消之前的訂閱
      await _scanSubscription?.cancel();

      // 訂閱掃描結果流，實時更新 UI
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        print('[HomeScreen] 收到掃描結果更新: ${results.length} 個裝置');

        // 打印所有裝置的詳細資訊
        for (var result in results) {
          final name = result.device.platformName;
          final advName = result.advertisementData.advName;
          print(
              '[HomeScreen]   - $name (advName: $advName, RSSI: ${result.rssi})');
        }

        setState(() {
          _scanResults = results;
        });
      });

      // 開始掃描（5 秒）
      print('[HomeScreen] 調用 FlutterBluePlus.startScan()...');
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 5),
      );

      print('[HomeScreen] ========== 掃描完成 ==========');
      print('[HomeScreen] 共找到 ${_scanResults.length} 個裝置');

      // 顯示 ESP32/Pico 裝置數量
      final targetDevices = _scanResults.where((r) {
        final name = r.device.platformName;
        final advName = r.advertisementData.advName;
        return name.contains('Pico') ||
            name.contains('ESP32') ||
            advName.contains('Pico') ||
            advName.contains('ESP32');
      }).length;

      if (targetDevices > 0) {
        print('[HomeScreen] ✅ 找到 $targetDevices 個 ESP32/Pico 裝置');
      } else if (_scanResults.isNotEmpty) {
        print('[HomeScreen] ⚠️ 找到 ${_scanResults.length} 個裝置，但無 ESP32/Pico');
      } else {
        print('[HomeScreen] ❌ 未找到任何裝置');
      }

      setState(() {
        _isScanning = false;
      });
    } catch (e) {
      print('[HomeScreen] 掃描錯誤: $e');
      setState(() {
        _isScanning = false;
      });
      _showMessage('掃描失敗: $e', isError: true);
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (!mounted || _isConnecting || _isBleConnected) return;
    setState(() {
      _isConnecting = true;
      _systemStatus = '正在連接';
      _isStorageReady = null;
      _storageStatus = '等待藍牙連線…';
    });

    // 顯示連接對話框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在連接到 ${device.platformName}...'),
          ],
        ),
      ),
    );

    final success = await _bleService.connectToDevice(device);

    if (mounted) {
      Navigator.of(context).pop();
    }

    if (success) {
      await _loadDeviceIdentity();
      await _refreshStorageStatus();
      _showMessage('✅ 連接成功！');
    } else {
      if (mounted) _applyDisconnectedState();
      final detail = _bleService.lastConnectionError;
      _showMessage(
        detail == null ? '❌ 連接失敗，請重試' : '❌ 連接失敗：$detail',
        isError: true,
      );
    }
  }

  Future<void> _disconnect() async {
    await _bleService.disconnect();
    _showMessage('已斷開連接');
  }

  Future<void> _loadDeviceIdentity() async {
    final info = await _bleService.readDeviceInfo();
    if (!mounted || info == null) return;
    setState(() {
      _deviceCode = info['device_code'] as String? ?? '';
      _hardwareUid = info['hardware_uid'] as String? ?? '';
      _isProvisionLocked = info['provision_locked'] == true;
    });
  }

  /// Asks the recorder rather than trusting a previously displayed SD state.
  /// This is used immediately after connecting and before every new recording.
  Future<bool> _refreshStorageStatus() async {
    if (!_isBleConnected) return false;
    if (_isCheckingStorage) return _isStorageReady == true;

    final completer = Completer<bool>();
    final requestId =
        _nextStorageRequestId = (_nextStorageRequestId + 1) & 0xff;
    setState(() {
      _isCheckingStorage = true;
      _isStorageReady = null;
      _storageStatus = '正在確認 SD 卡…';
    });
    _storageCheckCompleter = completer;
    _activeStorageRequestId = requestId;

    if (!await _bleService.checkStorage(requestId)) {
      if (mounted) {
        setState(() {
          _isCheckingStorage = false;
          _isStorageReady = false;
          _storageStatus = '無法確認 SD 卡狀態';
        });
      }
      _storageCheckCompleter = null;
      _activeStorageRequestId = null;
      return false;
    }

    try {
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } finally {
      if (identical(_storageCheckCompleter, completer)) {
        _storageCheckCompleter = null;
        _activeStorageRequestId = null;
      }
      if (mounted && _isCheckingStorage) {
        setState(() {
          _isCheckingStorage = false;
          if (_isStorageReady == null) {
            _isStorageReady = false;
            _storageStatus = '確認 SD 卡狀態逾時';
          }
        });
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (!_isBleConnected) {
      _showMessage('BLE 已斷線，請重新連線後再錄音', isError: true);
      return;
    }
    if (!_recordingState.canStop && !_isProvisionLocked) {
      _showMessage('設備尚未完成 USB 編號設定，無法開始錄音', isError: true);
      return;
    }
    if (!_recordingState.canStop && !await _refreshStorageStatus()) {
      _showMessage('SD 卡未就緒，無法開始錄音', isError: true);
      return;
    }
    if (_recordingWorkflowLocked && !_recordingState.canStop) {
      _showMessage('請先完成目前錄音的儲存流程', isError: true);
      return;
    }
    if (_recordingState.canStop) {
      setState(() {
        _recordingState = RecordingSessionState(
          phase: RecordingPhase.finalizing,
          sessionId: _recordingState.sessionId,
          detail: '已送出停止命令，等待錄音器完成 WAV',
        );
      });
      final requestId = await _bleService.stopRecording();
      if (requestId == null) {
        _setRecordingFailure('STOP_WRITE_FAILED', '無法將停止命令送至錄音器');
      } else {
        unawaited(_verifyStopAfterTimeout(_recordingState.sessionId));
      }
      return;
    }
    if (!_recordingState.canStart) return;

    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _recordingWorkflowLocked = true;
      _recordingState = RecordingSessionState(
        phase: RecordingPhase.starting,
        sessionId: sessionId,
        detail: '已送出開始命令，等待錄音器確認',
      );
    });
    final requestId = await _bleService.startRecording();
    if (requestId == null) {
      _setRecordingFailure('START_WRITE_FAILED', '無法將開始命令送至錄音器');
    } else {
      unawaited(_verifyStartAfterTimeout(sessionId));
    }
  }

  Future<void> _verifyStartAfterTimeout(String sessionId) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted ||
        _recordingState.sessionId != sessionId ||
        _recordingState.phase != RecordingPhase.starting) return;
    if (await _bleService.getRecorderStatus() == null) {
      _setRecordingFailure('START_UNCONFIRMED', '開始錄音逾時，且無法查詢錄音器狀態');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    if (mounted &&
        _recordingState.sessionId == sessionId &&
        _recordingState.phase == RecordingPhase.starting) {
      _setRecordingFailure('START_UNCONFIRMED', '開始錄音逾時；錄音器未回覆正在錄音');
    }
  }

  Future<void> _verifyStopAfterTimeout(String? sessionId) async {
    await Future<void>.delayed(const Duration(seconds: 10));
    if (!mounted ||
        _recordingState.sessionId != sessionId ||
        _recordingState.phase != RecordingPhase.finalizing) return;
    if (await _bleService.getRecorderStatus() == null) {
      _setRecordingFailure('STOP_UNCONFIRMED', '停止錄音逾時，且無法查詢錄音器狀態');
    }
  }

  String? get _recordingDisabledLabel {
    if (!_isBleConnected) return '請先連接錄音器';
    if (!_isProvisionLocked) return '尚未完成 USB 編號設定';
    if (_isCheckingStorage) return '正在確認 SD 卡';
    if (_isStorageReady != true) return 'SD 卡未就緒';
    if (_recordingWorkflowLocked) return '請完成表單流程';
    if (!_recordingState.canStart && !_recordingState.canStop) {
      return '請完成目前流程';
    }
    return null;
  }

  void _setRecordingFailure(String code, String detail) {
    if (!mounted) return;
    setState(() {
      _recordingState = RecordingSessionState(
        phase: RecordingPhase.failed,
        sessionId: _recordingState.sessionId,
        filename: _recordingState.filename,
        errorCode: code,
        detail: detail,
      );
    });
  }

  Future<String?> _saveWavFile(String filename, List<int> data,
      {int? expectedSize}) async {
    try {
      final validationError =
          WavValidator.validate(data, expectedFileSize: expectedSize);
      if (validationError != null) {
        print('[HomeScreen] WAV 驗證失敗: $validationError');
        return null;
      }
      // 取得 App 專屬目錄
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');

      // 建立目錄（如果不存在）
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      // Write a temporary file first, then rename only after its write is done.
      final file = File('${recordingsDir.path}/$filename');
      final temporaryFile = File('${file.path}.part');
      await temporaryFile.writeAsBytes(data, flush: true);
      if (await file.exists()) await file.delete();
      await temporaryFile.rename(file.path);

      print('[HomeScreen] WAV 檔案已存至: ${file.path}');
      return file.path;
    } catch (e) {
      print('[HomeScreen] 儲存 WAV 失敗: $e');
      return null;
    }
  }

  Future<void> _openRecordingForm(RecordingInfo recordingInfo) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => RecordingFormScreen(
        recordingInfo: recordingInfo,
        onSubmit: (userData) => _submitMetadata(recordingInfo, userData),
        onCancel: _cancelRecordingForm,
      ),
    ));
    if (!mounted) return;
    if (saved == true) {
      setState(() {
        _currentRecordingInfo = null;
        _recordingState = const RecordingSessionState.idle();
        _recordingWorkflowLocked = false;
      });
      _showMessage('✅ 資料已全部儲存，現在可以開始下一次錄音');
    }
  }

  Future<String?> _submitMetadata(
      RecordingInfo recordingInfo, UserData userData) async {
    _metadataSaveCompleter = Completer<String?>();
    setState(() {
      _recordingState = RecordingSessionState(
        phase: RecordingPhase.savingMetadata,
        sessionId: _recordingState.sessionId,
        filename: recordingInfo.autoData.wavFilename,
        detail: '已送出表單資料，等待錄音器 SD 寫入確認',
      );
    });
    if (!await _bleService.sendUserData(
        recordingInfo.autoData.wavFilename, userData.toJson())) {
      _metadataSaveCompleter = null;
      setState(() {
        _recordingState = RecordingSessionState(
            phase: RecordingPhase.saved,
            sessionId: _recordingState.sessionId,
            filename: recordingInfo.autoData.wavFilename,
            detail: '無法將表單資料送至錄音器，可重試');
      });
      return '無法將表單資料送至錄音器';
    }
    final result = await _metadataSaveCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => '等待錄音器 SD 寫入確認逾時',
    );
    _metadataSaveCompleter = null;
    if (result != null && mounted) {
      setState(() {
        _recordingState = RecordingSessionState(
            phase: RecordingPhase.saved,
            sessionId: _recordingState.sessionId,
            filename: recordingInfo.autoData.wavFilename,
            detail: '表單資料未儲存：$result，可重試');
      });
    }
    return result;
  }

  Future<void> _cancelRecordingForm() async {
    if (!mounted) return;
    setState(() {
      _currentRecordingInfo = null;
      _recordingState = const RecordingSessionState.idle();
      _recordingWorkflowLocked = false;
    });
    _showMessage('已取消；SD 卡上的 WAV 仍保留');
  }

  @override
  Widget build(BuildContext context) {
    final connectionStatusCard = ConnectionStatusCard(
      isConnected: _bleService.isConnected,
      systemStatus: _systemStatus,
      lastFilename: _lastFilename,
      storageStatus: _storageStatus,
      isStorageReady: _isStorageReady,
      deviceCode: _deviceCode,
      hardwareUid: _hardwareUid,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pico 藍牙排尿記錄器'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          if (_bleService.isConnected) ...[
            IconButton(
              icon: const Icon(Icons.history),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        HistoryScreen(bleService: _bleService),
                  ),
                );
              },
              tooltip: '歷史記錄',
            ),
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: _disconnect,
              tooltip: '斷開連接',
            ),
          ],
        ],
      ),
      body: _isBleConnected
          ? LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 32,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      connectionStatusCard,
                      const SizedBox(height: 20),
                      RecordingControlsView(
                        recordingState: _recordingState,
                        canStartRecording: _recordingState.canStart &&
                            _isBleConnected &&
                            !_recordingWorkflowLocked &&
                            !_isCheckingStorage &&
                            _isProvisionLocked &&
                            _isStorageReady == true,
                        disabledLabel: _recordingDisabledLabel,
                        onToggleRecording: _toggleRecording,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  connectionStatusCard,
                  const SizedBox(height: 20),
                  Expanded(
                    child: DeviceScannerView(
                      isScanning: _isScanning,
                      isBluetoothReady:
                          _adapterState == BluetoothAdapterState.on,
                      bluetoothStatus: _bluetoothStatus,
                      scanResults: _scanResults,
                      onStartScan: _startScan,
                      onDeviceSelected: _connectToDevice,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
