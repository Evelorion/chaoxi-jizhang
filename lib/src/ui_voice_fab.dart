part of 'app.dart';

class VoiceRecordingFab extends StatefulWidget {
  const VoiceRecordingFab({required this.book, required this.controller, super.key});
  final LedgerBook book;
  final LedgerController controller;
  
  @override
  State<VoiceRecordingFab> createState() => _VoiceRecordingFabState();
}

class _VoiceRecordingFabState extends State<VoiceRecordingFab> with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speechToText = stt.SpeechToText();
  bool _speechEnabled = false;
  String _lastWords = '';
  bool _isListening = false;
  NlpExtractionResult? _currentResult;
  late AnimationController _animController;
  
  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
    _initSpeech();
  }
  
  void _initSpeech() async {
    try {
      _speechEnabled = await _speechToText.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
             if (mounted && _isListening) {
               _stopListening();
             }
          }
        },
      );
    } catch(e) {
      _speechEnabled = false;
    }
    if (mounted) setState(() {});
  }
  
  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }
  
  void _startListening() async {
    if (!_speechEnabled) {
      // Fallback: System STT failed, show a beautiful floating dialog with TextField for keyboard voice
      final typed = await showDialog<String>(context: context, builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('💡 魔法记账'),
        content: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: '点键盘🎤说话, 或打字...', 
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
            filled: true,
            fillColor: const Color(0xFFF5F7FA)
          ),
          onSubmitted: (val) => Navigator.pop(context, val),
        ),
      ));
      if (typed != null && typed.isNotEmpty) {
        _currentResult = NlpParser.parse(typed);
        _lastWords = typed;
        _submitEntryFallback();
      }
      return;
    }
    _lastWords = '';
    _currentResult = null;
    setState(() => _isListening = true);
    _animController.forward(from: 0);
    _animController.repeat(reverse: true);
    
    await _speechToText.listen(
      onResult: (result) {
        setState(() {
          _lastWords = result.recognizedWords;
          if (_lastWords.isNotEmpty) {
            _currentResult = NlpParser.parse(_lastWords);
          }
        });
      },
      localeId: 'zh_CN',
    );
  }
  
  void _stopListening() async {
    await _speechToText.stop();
    setState(() => _isListening = false);
    if (_currentResult != null && _currentResult!.isComplete && _currentResult!.amount != null) {
      _submitEntry();
    } else {
      if (_lastWords.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('听到"$_lastWords"，但无法识别出金额。已丢弃。')));
      }
    }
  }
  
  Future<void> _submitEntryFallback() async {
    final result = _currentResult;
    if (result == null || !result.isComplete || result.amount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未能从这句话中识别出金额哦')));
      return;
    }

    final entry = LedgerEntry(
      id: _uuid.v4(),
      title: result.item.isEmpty ? (result.merchant.isEmpty ? '魔法AI记账' : result.merchant) : result.item,
      merchant: result.merchant,
      note: 'AI语义转写: $_lastWords',
      amount: result.amount!,
      type: EntryType.expense,
      categoryId: result.categoryId ?? widget.book.settings.defaultExpenseCategoryId,
      channel: PaymentChannel.wechatPay,
      occurredAt: result.date ?? DateTime.now(),
      autoCaptured: false,
      sourceLabel: '魔法指令',
      mood: ExpenseMood.chill,
    );
    await widget.controller.addEntry(entry);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('✨ 魔法记账成功：记录了 ￥${result.amount!.toStringAsFixed(2)}！'), backgroundColor: const Color(0xFF0B8457)));
    }
  }

  Future<void> _submitEntry() async {
    final result = _currentResult;
    if (result == null || !result.isComplete || result.amount == null) return;

    final entry = LedgerEntry(
      id: _uuid.v4(),
      title: result.item.isEmpty ? (result.merchant.isEmpty ? '语音AI记账' : result.merchant) : result.item,
      merchant: result.merchant,
      note: 'AI录音转写: $_lastWords',
      amount: result.amount!,
      type: EntryType.expense,
      categoryId: result.categoryId ?? widget.book.settings.defaultExpenseCategoryId,
      channel: PaymentChannel.wechatPay,
      occurredAt: result.date ?? DateTime.now(),
      autoCaptured: false,
      sourceLabel: '语音原生识别',
      mood: ExpenseMood.chill,
    );

    await widget.controller.addEntry(entry);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✨ 语音记账成功：记录了 ￥${result.amount!.toStringAsFixed(2)}！'),
          backgroundColor: const Color(0xFF0B8457),
        ),
      );
    }
  }

  void _openTextFallback() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final ctrl = TextEditingController();
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('AI 文本速记', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '如："昨天买水花了5块"',
                    filled: true,
                    fillColor: const Color(0xFFF5F7FA),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (val) {
                    if (val.trim().isNotEmpty) {
                      setState(() {
                         _lastWords = val.trim();
                         _currentResult = NlpParser.parse(_lastWords);
                         _submitEntry();
                      });
                      Navigator.pop(context);
                    }
                  },
                ),
                const SizedBox(height: 12),
                const Text('提示: 语音不可用时,可直接打字进行AI解析记账', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_isListening)
            Container(
              margin: const EdgeInsets.only(bottom: 16, right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(16),
              ),
              constraints: const BoxConstraints(maxWidth: 240),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_lastWords.isEmpty ? '请说话...' : _lastWords, style: const TextStyle(color: Colors.white, fontSize: 14)),
                  if (_currentResult != null && _currentResult!.amount != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text('✅ 识别金额: ￥${_currentResult!.amount!.toStringAsFixed(2)}', style: const TextStyle(color: Color(0xFF4A8BFF), fontSize: 13, fontWeight: FontWeight.bold)),
                    )
                ],
              ),
            ),
          GestureDetector(
            onTap: _openTextFallback,
            onLongPressStart: (_) => _startListening(),
            onLongPressEnd: (_) => _stopListening(),
            child: AnimatedBuilder(
              animation: _animController,
              builder: (context, child) {
                return Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening ? const Color(0xFF1E6CF7) : Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: _isListening ? const Color(0xFF1E6CF7).withValues(alpha: 0.5 * _animController.value) : Colors.black.withValues(alpha: 0.1),
                        blurRadius: _isListening ? 20 * _animController.value : 8,
                        spreadRadius: _isListening ? 10 * _animController.value : 0,
                        offset: const Offset(0, 4),
                      )
                    ]
                  ),
                  child: Icon(Icons.mic, color: _isListening ? Colors.white : const Color(0xFF1E6CF7), size: 32),
                );
              }
            ),
          ),
        ],
      ),
    );
  }
}
