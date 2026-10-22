/// recording.dart
/// 錄音記錄模型

class Recording {
  final int index;
  final int timestamp;
  final String filename;
  final double duration;
  final int filesize;
  final bool transferred;
  final int? urinationState;
  final String? notes;
  final Map<String, dynamic>? userData;

  Recording({
    required this.index,
    required this.timestamp,
    required this.filename,
    required this.duration,
    required this.filesize,
    this.transferred = false,
    this.urinationState,
    this.notes,
    this.userData,
  });

  /// 從 JSON 建立 Recording 物件
  factory Recording.fromJson(Map<String, dynamic> json) {
    return Recording(
      index: json['index'] as int,
      timestamp: json['timestamp'] as int,
      filename: json['filename'] as String,
      duration: (json['duration'] as num).toDouble(),
      filesize: json['filesize'] as int,
      transferred: json['transferred'] as bool? ?? false,
      urinationState: json['urination_state'] as int?,
      notes: json['notes'] as String?,
      userData: json['user_data'] as Map<String, dynamic>?,
    );
  }

  /// 轉換為 JSON
  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'timestamp': timestamp,
      'filename': filename,
      'duration': duration,
      'filesize': filesize,
      'transferred': transferred,
      if (urinationState != null) 'urination_state': urinationState,
      if (notes != null) 'notes': notes,
      if (userData != null) 'user_data': userData,
    };
  }

  /// 取得 DateTime 物件
  DateTime get dateTime {
    return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  }

  /// 取得格式化的日期時間字串
  String get formattedDateTime {
    final dt = dateTime;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
           '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  /// 取得格式化的檔案大小
  String get formattedFilesize {
    if (filesize < 1024) {
      return '$filesize B';
    } else if (filesize < 1024 * 1024) {
      return '${(filesize / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(filesize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  /// 取得格式化的時長
  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = (duration % 60).toInt();
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 複製並修改部分欄位
  Recording copyWith({
    int? index,
    int? timestamp,
    String? filename,
    double? duration,
    int? filesize,
    bool? transferred,
    int? urinationState,
    String? notes,
    Map<String, dynamic>? userData,
  }) {
    return Recording(
      index: index ?? this.index,
      timestamp: timestamp ?? this.timestamp,
      filename: filename ?? this.filename,
      duration: duration ?? this.duration,
      filesize: filesize ?? this.filesize,
      transferred: transferred ?? this.transferred,
      urinationState: urinationState ?? this.urinationState,
      notes: notes ?? this.notes,
      userData: userData ?? this.userData,
    );
  }
}
