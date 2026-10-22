import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/recording_data.dart';

class RecordingFormScreen extends StatefulWidget {
  const RecordingFormScreen({
    super.key,
    required this.recordingInfo,
    required this.onSubmit,
    required this.onCancel,
  });

  final RecordingInfo recordingInfo;
  final Future<String?> Function(UserData userData) onSubmit;
  final Future<void> Function() onCancel;

  @override
  State<RecordingFormScreen> createState() => _RecordingFormScreenState();
}

class _RecordingFormScreenState extends State<RecordingFormScreen> {
  final _formKey = GlobalKey<FormState>();
  String _posture = 'sitting';
  double _urgencyLevel = 2;
  final _intermittencyController = TextEditingController(text: '0');
  final _hesitancyController = TextEditingController(text: '0');
  final _notesController = TextEditingController();
  bool _hasDribbling = false;
  bool _hasNoiseInterference = false;
  bool _isSaving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final existing = widget.recordingInfo.userData;
    if (existing == null) return;
    _posture = existing.posture;
    _urgencyLevel = existing.urgencyLevel.toDouble();
    _intermittencyController.text = existing.intermittencyCount.toString();
    _hesitancyController.text = existing.hesitancySec.toString();
    _notesController.text = existing.notes;
    _hasDribbling = existing.hasDribbling;
    _hasNoiseInterference = existing.hasNoiseInterference;
  }

  @override
  void dispose() {
    _intermittencyController.dispose();
    _hesitancyController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    final error = await widget.onSubmit(UserData(
      posture: _posture,
      urgencyLevel: _urgencyLevel.round(),
      intermittencyCount: int.parse(_intermittencyController.text),
      hasDribbling: _hasDribbling,
      hesitancySec: int.parse(_hesitancyController.text),
      hasNoiseInterference: _hasNoiseInterference,
      notes: _notesController.text,
    ));
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _isSaving = false;
        _saveError = error;
      });
    }
  }

  Future<void> _cancel() async {
    if (_isSaving) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消編輯？'),
        content: const Text('不會變更 ESP32 SD 卡上的既有紀錄。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('繼續填寫')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('確認取消')),
        ],
      ),
    );
    if (discard == true) {
      await widget.onCancel();
      if (mounted) Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.recordingInfo.autoData;
    return PopScope(
      canPop: !_isSaving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('本次排尿紀錄'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _isSaving ? null : _cancel),
        ),
        body: Stack(
          children: [
            SafeArea(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(12)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('音檔已安全儲存至 ESP32 SD 卡',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 12),
                            _info('檔案', info.wavFilename),
                            _info('時長', '${info.recordingDurationSec} 秒'),
                            _info('時間', info.urinationTime),
                          ]),
                    ),
                    const SizedBox(height: 28),
                    const Text('請填寫排尿狀態',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 18),
                    _label('排尿姿勢'),
                    DropdownButtonFormField<String>(
                      value: _posture,
                      decoration:
                          const InputDecoration(border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'sitting', child: Text('坐姿')),
                        DropdownMenuItem(value: 'standing', child: Text('站姿'))
                      ],
                      onChanged: _isSaving
                          ? null
                          : (value) => setState(() => _posture = value!),
                    ),
                    const SizedBox(height: 18),
                    _label('急迫感程度：${_urgencyLevel.round()}'),
                    Slider(
                        value: _urgencyLevel,
                        min: 1,
                        max: 4,
                        divisions: 3,
                        label: _urgencyLevel.round().toString(),
                        onChanged: _isSaving
                            ? null
                            : (value) => setState(() => _urgencyLevel = value)),
                    _numberField(
                        '排尿中斷（Intermittency）', _intermittencyController, '次'),
                    _switch('滴尿（Dribbling）', _hasDribbling,
                        (value) => setState(() => _hasDribbling = value)),
                    _numberField('延遲（Hesitancy）', _hesitancyController, '秒'),
                    _switch(
                        '有無噪音干擾？',
                        _hasNoiseInterference,
                        (value) =>
                            setState(() => _hasNoiseInterference = value)),
                    _label('備註'),
                    TextFormField(
                        controller: _notesController,
                        enabled: !_isSaving,
                        maxLines: 3,
                        maxLength: 100,
                        buildCounter: (context,
                                {required currentLength,
                                required isFocused,
                                maxLength}) =>
                            Text('$currentLength / $maxLength'),
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: '輸入其他需要記錄的資訊…',
                            helperText: '最多 100 字；資料將儲存於錄音器 SD 卡')),
                    if (_saveError != null) ...[
                      const SizedBox(height: 16),
                      Text('儲存失敗：$_saveError',
                          style: const TextStyle(
                              color: Colors.red, fontWeight: FontWeight.bold)),
                    ],
                    const SizedBox(height: 28),
                    FilledButton.icon(
                        onPressed: _isSaving ? null : _submit,
                        icon: const Icon(Icons.save),
                        label: const Text('儲存紀錄'),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16))),
                    TextButton(
                        onPressed: _isSaving ? null : _cancel,
                        child: const Text('取消本次表單')),
                  ],
                ),
              ),
            ),
            if (_isSaving)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black45,
                  child: const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text('正在將表單資料寫入 ESP32 SD 卡…',
                        style: TextStyle(color: Colors.white, fontSize: 16))
                  ])),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _info(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 6), child: Text('$label：$value'));
  Widget _label(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)));
  Widget _numberField(
          String label, TextEditingController controller, String suffix) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 18),
        _label(label),
        TextFormField(
            controller: controller,
            enabled: !_isSaving,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
                border: const OutlineInputBorder(), suffixText: suffix),
            validator: (value) =>
                value == null || int.tryParse(value) == null ? '請輸入有效數字' : null)
      ]);
  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          title: Text(title),
          value: value,
          onChanged: _isSaving ? null : onChanged);
}
