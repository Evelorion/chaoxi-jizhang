part of 'app.dart';

/// Smart quick-entry FAB with polished UI.
/// Tap to open text input, use keyboard's built-in voice button for speech.
/// NLP auto-parses amount, merchant, category from whatever is typed/spoken.
class VoiceRecordingFab extends StatefulWidget {
  const VoiceRecordingFab({required this.book, required this.controller, super.key});
  final LedgerBook book;
  final LedgerController controller;

  @override
  State<VoiceRecordingFab> createState() => _VoiceRecordingFabState();
}

class _VoiceRecordingFabState extends State<VoiceRecordingFab>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 20,
      right: 20,
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (context, child) {
          final glow = 0.08 + (_pulseCtrl.value * 0.12);
          return GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              _openQuickEntry(context);
            },
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3B82F6).withValues(alpha: glow),
                    blurRadius: 20,
                    spreadRadius: 4,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 28),
            ),
          );
        },
      ),
    );
  }

  void _openQuickEntry(BuildContext outerContext) {
    showModalBottomSheet(
      context: outerContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionAnimationController: AnimationController(
        vsync: Navigator.of(outerContext),
        duration: const Duration(milliseconds: 300),
      ),
      builder: (sheetContext) => _QuickEntrySheet(
        book: widget.book,
        controller: widget.controller,
        outerContext: outerContext,
      ),
    );
  }
}

class _QuickEntrySheet extends StatefulWidget {
  const _QuickEntrySheet({required this.book, required this.controller, required this.outerContext});
  final LedgerBook book;
  final LedgerController controller;
  final BuildContext outerContext;

  @override
  State<_QuickEntrySheet> createState() => _QuickEntrySheetState();
}

class _QuickEntrySheetState extends State<_QuickEntrySheet> with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();
  NlpExtractionResult? _preview;
  bool _submitting = false;
  late AnimationController _enterAnim;

  @override
  void initState() {
    super.initState();
    _enterAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 400))
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    _enterAnim.dispose();
    super.dispose();
  }

  void _onTextChanged(String val) {
    if (val.trim().isNotEmpty) {
      setState(() => _preview = NlpParser.parse(val.trim()));
    } else {
      setState(() => _preview = null);
    }
  }

  Future<void> _submit(String val) async {
    if (val.trim().isEmpty || _submitting) return;
    final result = NlpParser.parse(val.trim());
    if (result.amount == null) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(widget.outerContext).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('未识别到金额，请输入数字金额'),
            ],
          ),
          backgroundColor: const Color(0xFFE65100),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    final entry = LedgerEntry(
      id: _uuid.v4(),
      title: result.item.isNotEmpty
          ? result.item
          : (result.merchant.isNotEmpty ? result.merchant : '速记'),
      merchant: result.merchant,
      note: '智能速记: ${val.trim()}',
      amount: result.amount!,
      type: result.isIncome ? EntryType.income : EntryType.expense,
      categoryId: result.isIncome
          ? (result.categoryId ?? 'salary')
          : (result.categoryId ?? widget.book.settings.defaultExpenseCategoryId),
      channel: PaymentChannel.wechatPay,
      occurredAt: result.date ?? DateTime.now(),
      autoCaptured: false,
      sourceLabel: '智能速记',
      mood: ExpenseMood.chill,
    );

    await widget.controller.addEntry(entry);

    if (mounted) Navigator.pop(context);

    if (widget.outerContext.mounted) {
      final typeLabel = result.isIncome ? '收入' : '支出';
      final icon = result.isIncome ? '📥' : '📤';
      ScaffoldMessenger.of(widget.outerContext).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$typeLabel ￥${result.amount!.toStringAsFixed(2)}'
                  '${result.merchant.isNotEmpty ? " · ${result.merchant}" : ""}'
                  '${result.item.isNotEmpty && result.item != result.merchant ? " · ${result.item}" : ""}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.check_circle, color: Colors.white, size: 18),
            ],
          ),
          backgroundColor: result.isIncome ? const Color(0xFF0B8457) : const Color(0xFF1D4ED8),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    final hasResult = p != null && p.amount != null;

    return AnimatedBuilder(
      animation: _enterAnim,
      builder: (context, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: _enterAnim, curve: Curves.easeOut),
          child: child,
        );
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Handle bar ──
              Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // ── Header ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEF2FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.bolt_rounded, color: Color(0xFF3B82F6), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('智能速记', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                        Text('输入文字或用键盘语音 🎤', style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.5)),
                      ],
                    ),
                  ),
                  // Type toggle indicator
                  if (hasResult)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: p!.isIncome ? const Color(0xFFDCFCE7) : const Color(0xFFDBEAFE),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        p.isIncome ? '收入' : '支出',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: p.isIncome ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Input field ──
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B82F6).withValues(alpha: hasResult ? 0.08 : 0.0),
                      blurRadius: 12,
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focusNode,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: '星巴克咖啡35、打车15块、收入500...',
                    hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w400),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: hasResult ? const Color(0xFF3B82F6).withValues(alpha: 0.3) : Colors.transparent),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: hasResult ? const Color(0xFF3B82F6).withValues(alpha: 0.3) : const Color(0xFFE2E8F0)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    prefixIcon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        hasResult ? Icons.check_circle_rounded : Icons.search_rounded,
                        key: ValueKey(hasResult),
                        color: hasResult ? const Color(0xFF16A34A) : Colors.grey.shade400,
                        size: 20,
                      ),
                    ),
                    suffixIcon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: hasResult
                          ? Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: _submitting ? null : () => _submit(_ctrl.text),
                                child: Container(
                                  margin: const EdgeInsets.all(6),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: _submitting
                                      ? const SizedBox(width: 16, height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 16),
                                ),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.all(12),
                              child: Icon(Icons.mic_none_rounded, color: Colors.grey.shade400, size: 22),
                            ),
                    ),
                  ),
                  onChanged: _onTextChanged,
                  onSubmitted: _submit,
                ),
              ),

              // ── NLP Preview card ──
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                child: hasResult
                    ? Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: p!.isIncome
                                ? [const Color(0xFFF0FDF4), const Color(0xFFDCFCE7)]
                                : [const Color(0xFFEFF6FF), const Color(0xFFDBEAFE)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: p.isIncome
                                ? const Color(0xFF86EFAC).withValues(alpha: 0.5)
                                : const Color(0xFF93C5FD).withValues(alpha: 0.5),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Amount row
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '￥',
                                  style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600,
                                    color: p.isIncome ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  p.amount!.toStringAsFixed(2),
                                  style: TextStyle(
                                    fontSize: 28, fontWeight: FontWeight.w800, height: 1,
                                    color: p.isIncome ? const Color(0xFF16A34A) : const Color(0xFF1E40AF),
                                    letterSpacing: -1,
                                  ),
                                ),
                                const Spacer(),
                                Icon(
                                  p.isIncome ? Icons.south_west_rounded : Icons.north_east_rounded,
                                  color: p.isIncome ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
                                  size: 20,
                                ),
                              ],
                            ),
                            // Details row
                            if (p.merchant.isNotEmpty || p.item.isNotEmpty || p.categoryId != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    if (p.merchant.isNotEmpty)
                                      _PreviewTag(Icons.storefront_rounded, p.merchant),
                                    if (p.item.isNotEmpty && p.item != p.merchant)
                                      _PreviewTag(Icons.shopping_bag_outlined, p.item),
                                    if (p.categoryId != null)
                                      _PreviewTag(Icons.category_outlined, _categoryLabel(p.categoryId!)),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // ── Quick chips ──
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: !hasResult
                    ? Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('快捷示例', style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _QuickChip('午饭35', _ctrl, _onTextChanged),
                                _QuickChip('打车15块', _ctrl, _onTextChanged),
                                _QuickChip('星巴克38', _ctrl, _onTextChanged),
                                _QuickChip('收入5000', _ctrl, _onTextChanged),
                                _QuickChip('超市水果68', _ctrl, _onTextChanged),
                                _QuickChip('奶茶12块', _ctrl, _onTextChanged),
                              ],
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  String _categoryLabel(String id) {
    const map = {
      'food': '餐饮', 'mobility': '出行', 'shopping': '购物',
      'entertainment': '娱乐', 'housing': '居住', 'health': '医疗',
      'education': '教育', 'salary': '收入', 'daily': '日常',
    };
    return map[id] ?? id;
  }
}

class _PreviewTag extends StatelessWidget {
  const _PreviewTag(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFF64748B)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip(this.text, this.ctrl, this.onChanged);
  final String text;
  final TextEditingController ctrl;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        ctrl.text = text;
        ctrl.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
        onChanged(text);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, color: Color(0xFF475569), fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
