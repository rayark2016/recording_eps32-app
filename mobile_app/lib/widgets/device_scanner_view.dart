/// device_scanner_view.dart
/// 設備掃描與列表 Widget

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class DeviceScannerView extends StatelessWidget {
  static const _recorderName = 'ESP32_Pico_Recorder';
  final bool isScanning;
  final bool isBluetoothReady;
  final String bluetoothStatus;
  final List<ScanResult> scanResults;
  final VoidCallback onStartScan;
  final Function(BluetoothDevice) onDeviceSelected;

  const DeviceScannerView({
    super.key,
    required this.isScanning,
    required this.isBluetoothReady,
    required this.bluetoothStatus,
    required this.scanResults,
    required this.onStartScan,
    required this.onDeviceSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 掃描按鈕
        ElevatedButton.icon(
          onPressed: isScanning || !isBluetoothReady ? null : onStartScan,
          icon: isScanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.bluetooth_searching),
          label: Text(isScanning
              ? '掃描中...'
              : isBluetoothReady
                  ? '掃描裝置'
                  : '等待藍牙就緒'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          bluetoothStatus,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isBluetoothReady ? Colors.green : Colors.orange,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 6),

        // 設備列表
        Expanded(
          child: scanResults.isEmpty ? _buildEmptyState() : _buildDeviceList(),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isScanning ? Icons.bluetooth_searching : Icons.bluetooth,
            size: 64,
            color: isScanning ? Colors.blue : Colors.grey,
          ),
          const SizedBox(height: 16),
          Text(
            isScanning
                ? '正在搜尋裝置...'
                : isBluetoothReady
                    ? '請點擊上方按鈕掃描裝置'
                    : bluetoothStatus,
            style: TextStyle(
              fontSize: 16,
              color: isScanning ? Colors.blue : Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '提示：確保 ESP32 已開啟',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    // flutter_blue_plus returns results in discovery order, which changes from
    // scan to scan.  Prioritize our recorder regardless of discovery timing.
    final sortedResults = List<ScanResult>.from(scanResults)
      ..sort((a, b) {
        final priorityComparison =
            _devicePriority(a).compareTo(_devicePriority(b));
        if (priorityComparison != 0) return priorityComparison;
        return b.rssi.compareTo(a.rssi);
      });

    return ListView.builder(
      itemCount: sortedResults.length,
      itemBuilder: (context, index) {
        final result = sortedResults[index];
        final device = result.device;
        final name = device.platformName.isEmpty
            ? result.advertisementData.advName
            : device.platformName;

        final isRecorder = _devicePriority(result) == 0;
        final isTargetDevice = isRecorder ||
            name.toLowerCase().contains('pico') ||
            name.toLowerCase().contains('esp32');

        return Card(
          child: ListTile(
            leading: Icon(
              Icons.bluetooth,
              color: isTargetDevice ? Colors.blue : Colors.grey,
            ),
            title: Row(
              children: [
                Expanded(child: Text(name.isEmpty ? '未知裝置' : name)),
                if (isRecorder)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      '錄音器',
                      style: TextStyle(color: Colors.blue, fontSize: 12),
                    ),
                  ),
              ],
            ),
            subtitle: Text(
              '${device.remoteId}\nRSSI: ${result.rssi} dBm',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onDeviceSelected(device),
          ),
        );
      },
    );
  }

  int _devicePriority(ScanResult result) {
    final platformName = result.device.platformName.trim().toLowerCase();
    final advertisedName =
        result.advertisementData.advName.trim().toLowerCase();
    final recorderName = _recorderName.toLowerCase();

    if (platformName == recorderName || advertisedName == recorderName) {
      return 0;
    }
    if (platformName.contains('esp32') ||
        platformName.contains('pico') ||
        advertisedName.contains('esp32') ||
        advertisedName.contains('pico')) {
      return 1;
    }
    return 2;
  }
}
