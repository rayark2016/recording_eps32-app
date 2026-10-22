/// urination_state.dart
/// 排尿狀態定義

class UrinationState {
  final int value;
  final String name;
  final String description;

  const UrinationState({
    required this.value,
    required this.name,
    required this.description,
  });

  /// 所有排尿狀態選項
  static const List<UrinationState> all = [
    UrinationState(value: 1, name: '正常', description: 'Normal'),
    UrinationState(value: 2, name: '尿流微弱', description: 'Weak Stream'),
    UrinationState(value: 3, name: '尿流中斷', description: 'Interrupted Stream'),
    UrinationState(value: 4, name: '滴尿', description: 'Dribbling'),
    UrinationState(value: 5, name: '頻尿', description: 'Frequent Urination'),
    UrinationState(value: 6, name: '夜尿', description: 'Nocturia'),
    UrinationState(value: 7, name: '急迫性尿失禁', description: 'Urgency Incontinence'),
    UrinationState(value: 8, name: '排尿困難', description: 'Difficulty Urinating'),
    UrinationState(value: 9, name: '其他', description: 'Other'),
  ];

  /// 根據 value 取得對應的狀態
  static UrinationState? fromValue(int value) {
    try {
      return all.firstWhere((state) => state.value == value);
    } catch (e) {
      return null;
    }
  }

  /// 取得狀態名稱（根據 value）
  static String getNameByValue(int value) {
    final state = fromValue(value);
    return state?.name ?? '未知';
  }

  @override
  String toString() => name;
}
