/// connection_status_card.dart
/// 連接狀態卡片 Widget

import 'package:flutter/material.dart';

class ConnectionStatusCard extends StatelessWidget {
  final bool isConnected;
  final String systemStatus;
  final String lastFilename;
  final String storageStatus;
  final bool? isStorageReady;
  final String deviceCode;
  final String hardwareUid;

  const ConnectionStatusCard({
    super.key,
    required this.isConnected,
    required this.systemStatus,
    required this.lastFilename,
    required this.storageStatus,
    required this.isStorageReady,
    required this.deviceCode,
    required this.hardwareUid,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: isConnected ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  '藍牙：${isConnected ? '已連接' : '未連接'}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '裝置狀態：$systemStatus',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            if (isConnected) ...[
              const SizedBox(height: 4),
              Text(
                '設備：${deviceCode.isEmpty ? '讀取中…' : deviceCode}'
                '${hardwareUid.isEmpty ? '' : '  ·  UID: $hardwareUid'}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
            if (lastFilename.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '最後檔案: $lastFilename',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (isConnected) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(
                  isStorageReady == true ? Icons.sd_card : Icons.sd_card_alert,
                  size: 18,
                  color: isStorageReady == true ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Text(storageStatus,
                    style: TextStyle(
                        color: isStorageReady == true
                            ? Colors.green.shade700
                            : Colors.orange.shade800,
                        fontWeight: FontWeight.w600)),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
