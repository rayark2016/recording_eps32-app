/// history_screen.dart
/// 歷史記錄畫面

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/recording_data.dart';
import '../services/ble_service.dart';
import 'recording_form_screen.dart';

class HistoryScreen extends StatefulWidget {
  final BLEService bleService;

  const HistoryScreen({
    super.key,
    required this.bleService,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _records = [];
  Map<String, dynamic>? _flashInfo;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Subscribe before writing LIST. A fast ESP32 can otherwise publish the
      // first notification before `first` has installed its listener.
      final recordListFuture = widget.bleService.recordListStream.first.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException('載入記錄超時');
        },
      );
      final requested = await widget.bleService.requestRecordList();
      if (!requested) {
        throw StateError('無法送出歷史紀錄請求');
      }
      final recordListJson = await recordListFuture;

      final data = jsonDecode(recordListJson) as Map<String, dynamic>;
      if (data['type'] != 'record_list') {
        throw const FormatException('無效的歷史紀錄格式');
      }
      final records = (data['records'] as List<dynamic>? ?? const []);
      final storageInfo = <String, dynamic>{
        'free_bytes': data['free_bytes'],
        'total_count': data['total_count'] ?? records.length,
      };

      setState(() {
        _records = records.cast<Map<String, dynamic>>();
        _flashInfo = storageInfo;
        _isLoading = false;
      });
    } catch (e) {
      print('[History] 載入記錄失敗: $e');
      setState(() {
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('載入記錄失敗: $e')),
        );
      }
    }
  }

  String _formatDuration(double duration) {
    final minutes = (duration / 60).floor();
    final seconds = (duration % 60).floor();
    if (minutes > 0) {
      return '$minutes分$seconds秒';
    }
    return '$seconds秒';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  void _showRecordDetails(Map<String, dynamic> record) {
    final filename = record['filename'] as String;
    final duration = (record['duration_sec'] as num).toDouble();
    final filesize = (record['filesize'] as num).toInt();
    final metadataSaved = record['metadata_saved'] as bool? ?? false;
    final recordedAt = record['recorded_at'] as String? ?? '未知';

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('WAV 詳細資訊',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            _detailRow('檔名', filename),
            _detailRow('儲存位置', 'ESP32 SD 卡 /recordings'),
            _detailRow('檔案大小', _formatFileSize(filesize)),
            _detailRow('錄音時長', _formatDuration(duration)),
            _detailRow('錄音時間', recordedAt),
            _detailRow('表單資料', metadataSaved ? '已儲存同名 JSON' : '尚未儲存'),
            const SizedBox(height: 12),
            const Text(
              '音檔保留在 SD 卡；可讀取並編輯同名 JSON 的表單資料，不會透過藍牙下載 WAV。',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _editRecord(record);
                },
                icon: const Icon(Icons.edit_note),
                label: const Text('編輯表單紀錄'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 82,
              child: Text(label, style: const TextStyle(color: Colors.black54)),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  UserData? _userDataFromMetadata(Map<String, dynamic> metadata) {
    final raw = metadata['user_data'];
    if (raw is! Map<String, dynamic>) return null;
    return UserData(
      posture: raw['posture'] as String? ?? 'sitting',
      urgencyLevel: (raw['urgency_level'] as num?)?.toInt() ?? 2,
      intermittencyCount: (raw['intermittency_count'] as num?)?.toInt() ?? 0,
      hasDribbling: raw['has_dribbling'] as bool? ?? false,
      hesitancySec: (raw['hesitancy_sec'] as num?)?.toInt() ?? 0,
      hasNoiseInterference: raw['has_noise_interference'] as bool? ?? false,
      notes: raw['notes'] as String? ?? '',
    );
  }

  Future<void> _editRecord(Map<String, dynamic> record) async {
    final filename = record['filename'] as String;
    try {
      final responseFuture = widget.bleService.recordDataStream
          .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
          .where((data) =>
              data['type'] == 'metadata' && data['filename'] == filename)
          .first
          .timeout(const Duration(seconds: 12));
      if (!await widget.bleService.requestRecordData(filename)) {
        throw StateError('無法請求 JSON 紀錄');
      }
      final response = await responseFuture;
      if (response['status'] != 'success') {
        throw StateError(response['message'] as String? ?? '讀取 JSON 失敗');
      }
      final metadata = response['metadata'] as Map<String, dynamic>? ?? {};
      final duration = (record['duration_sec'] as num?)?.toInt() ?? 0;
      final recordingInfo = RecordingInfo(
        autoData: AutoData(
          urinationTime: metadata['recorded_at'] as String? ?? '未知時間',
          deviceId: metadata['device_code'] as String? ?? '未知設備',
          recordingDurationSec:
              (metadata['recording_duration_sec'] as num?)?.toInt() ?? duration,
          wavFilename: filename,
        ),
        userData: _userDataFromMetadata(metadata),
        status: 'saved',
      );

      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => RecordingFormScreen(
          recordingInfo: recordingInfo,
          onSubmit: (userData) => _saveEditedMetadata(filename, userData),
          onCancel: () async {},
        ),
      ));
      if (saved == true && mounted) {
        _showMessage('紀錄已更新至 ESP32 SD 卡');
        await _loadRecords();
      }
    } catch (e) {
      if (mounted) _showMessage('讀取或編輯紀錄失敗：$e', isError: true);
    }
  }

  Future<String?> _saveEditedMetadata(
      String filename, UserData userData) async {
    final confirmed = widget.bleService.confirmStream
        .where((message) =>
            message['operation'] == 'metadata_saved' &&
            message['filename'] == filename)
        .first
        .timeout(const Duration(seconds: 12));
    if (!await widget.bleService.sendUserData(filename, userData.toJson())) {
      return '無法將更新資料送至錄音器';
    }
    try {
      final response = await confirmed;
      if (response['status'] == 'success') return null;
      return response['message'] as String? ?? 'SD 寫入失敗';
    } catch (_) {
      return '等待 ESP32 SD 寫入確認逾時';
    }
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

  Widget _buildFlashInfoCard() {
    if (_flashInfo == null) {
      return const SizedBox.shrink();
    }

    final freeBytes = (_flashInfo!['free_bytes'] as num?)?.toInt();
    final totalCount = (_flashInfo!['total_count'] as num).toInt();

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sd_storage, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  'ESP32 SD 卡歷史紀錄',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '記錄數：$totalCount  |  可用空間：${freeBytes == null ? '未測量' : _formatFileSize(freeBytes)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('歷史記錄'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRecords,
            tooltip: '重新載入',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history,
                        size: 80,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '暫無記錄',
                        style: TextStyle(
                          fontSize: 18,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadRecords,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _records.length + 1, // +1 for Flash info card
                    itemBuilder: (context, index) {
                      // 第一項顯示 Flash 資訊
                      if (index == 0) {
                        return _buildFlashInfoCard();
                      }

                      // 後續顯示記錄
                      final record = _records[index - 1];
                      final filename = record['filename'] as String;
                      final duration =
                          (record['duration_sec'] as num).toDouble();
                      final filesize = record['filesize'] as int;
                      final metadataSaved =
                          record['metadata_saved'] as bool? ?? false;
                      final recordedAt =
                          record['recorded_at'] as String? ?? '未知';

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                metadataSaved ? Colors.green : Colors.blue,
                            child: Icon(
                              metadataSaved ? Icons.description : Icons.mic,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            filename,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text('錄音時間：$recordedAt'),
                              Text(
                                  '時長: ${_formatDuration(duration)} | 大小: ${_formatFileSize(filesize)}'),
                              Text(metadataSaved ? '表單資料：已儲存' : '表單資料：未儲存'),
                            ],
                          ),
                          trailing:
                              const Icon(Icons.sd_storage, color: Colors.blue),
                          isThreeLine: true,
                          onTap: () {
                            _showRecordDetails(record);
                          },
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
