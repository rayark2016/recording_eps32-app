/// main.dart
/// ESP32 Pico 藍牙排尿記錄系統 APP 入口

import 'package:flutter/material.dart';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UrinationRecorderApp());
}

class UrinationRecorderApp extends StatelessWidget {
  const UrinationRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '排尿記錄系統',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const PermissionGate(),
    );
  }
}

/// Keep the permission flow that was proven in version 4.  The recorder screen
/// is not entered until iOS/Android has granted the BLE permissions it needs.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _requestInProgress = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    if (_requestInProgress) return;
    _requestInProgress = true;
    setState(() => _error = null);

    try {
      final requiredPermissions = Platform.isIOS
          ? <Permission>[Permission.bluetooth]
          : <Permission>[
              Permission.bluetoothScan,
              Permission.bluetoothConnect,
            ];
      final statuses = await requiredPermissions.request();

      // iOS BLE scans are authorized by CoreBluetooth.  Location permission
      // is not required, and treating it as mandatory traps users here even
      // when Bluetooth is already enabled in Settings.
      final bluetoothGranted = Platform.isIOS
          ? (statuses[Permission.bluetooth]?.isGranted ?? false)
          : (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
              (statuses[Permission.bluetoothConnect]?.isGranted ?? false);

      if (!mounted) return;
      if (bluetoothGranted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      } else {
        setState(() => _error = '需要藍牙權限才能掃描 ESP32 Pico。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '權限初始化失敗：$error');
      }
    } finally {
      _requestInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bluetooth_searching, size: 72, color: Colors.blue),
              const SizedBox(height: 16),
              const Text('排尿記錄系統', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (_error == null) ...[
                const Text('正在檢查藍牙權限…'),
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ] else ...[
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _requestPermissions,
                  child: const Text('再次請求權限'),
                ),
                TextButton(
                  onPressed: openAppSettings,
                  child: const Text('前往設定'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
