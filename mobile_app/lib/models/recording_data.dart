import 'dart:convert';

/// 機器自動生成的資料
class AutoData {
  final String urinationTime;
  final String deviceId;
  final int recordingDurationSec;
  final String wavFilename;

  AutoData({
    required this.urinationTime,
    required this.deviceId,
    required this.recordingDurationSec,
    required this.wavFilename,
  });

  factory AutoData.fromJson(Map<String, dynamic> json) {
    return AutoData(
      urinationTime: json['urination_time'] as String,
      deviceId: json['device_id'] as String,
      recordingDurationSec: json['recording_duration_sec'] as int,
      wavFilename: json['wav_filename'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'urination_time': urinationTime,
      'device_id': deviceId,
      'recording_duration_sec': recordingDurationSec,
      'wav_filename': wavFilename,
    };
  }
}

/// 使用者填寫的資料
class UserData {
  final String posture;              // "sitting" 或 "standing"
  final int urgencyLevel;            // 1-4 (1=輕微, 4=急迫)
  final int intermittencyCount;      // 排尿中斷次數
  final bool hasDribbling;           // 是否有滴尿
  final int hesitancySec;            // 延遲秒數
  final bool hasNoiseInterference;   // 是否有噪音干擾
  final String notes;                // 備註

  UserData({
    required this.posture,
    required this.urgencyLevel,
    required this.intermittencyCount,
    required this.hasDribbling,
    required this.hesitancySec,
    required this.hasNoiseInterference,
    required this.notes,
  });

  factory UserData.fromJson(Map<String, dynamic> json) {
    return UserData(
      posture: json['posture'] as String,
      urgencyLevel: json['urgency_level'] as int,
      intermittencyCount: json['intermittency_count'] as int,
      hasDribbling: json['has_dribbling'] as bool,
      hesitancySec: json['hesitancy_sec'] as int,
      hasNoiseInterference: json['has_noise_interference'] as bool,
      notes: json['notes'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'posture': posture,
      'urgency_level': urgencyLevel,
      'intermittency_count': intermittencyCount,
      'has_dribbling': hasDribbling,
      'hesitancy_sec': hesitancySec,
      'has_noise_interference': hasNoiseInterference,
      'notes': notes,
    };
  }
}

/// 完整的錄音記錄資訊
class RecordingInfo {
  final AutoData autoData;
  final UserData? userData;
  final String status;

  RecordingInfo({
    required this.autoData,
    this.userData,
    required this.status,
  });

  factory RecordingInfo.fromJson(Map<String, dynamic> json) {
    return RecordingInfo(
      autoData: AutoData.fromJson(json['auto_data'] as Map<String, dynamic>),
      userData: json['user_data'] != null
          ? UserData.fromJson(json['user_data'] as Map<String, dynamic>)
          : null,
      status: json['status'] as String,
    );
  }

  factory RecordingInfo.fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return RecordingInfo.fromJson(json);
  }

  Map<String, dynamic> toJson() {
    return {
      'auto_data': autoData.toJson(),
      'user_data': userData?.toJson(),
      'status': status,
    };
  }

  String toJsonString() {
    return jsonEncode(toJson());
  }
}
