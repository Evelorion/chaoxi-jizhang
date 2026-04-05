import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. Inject selectedMood variable
  final stateInitTarget = 'var type = initialType;\n  var channel = initialEntry?.channel ?? PaymentChannel.wechatPay;';
  text = text.replaceFirst(stateInitTarget, 'var type = initialType;\n  var channel = initialEntry?.channel ?? PaymentChannel.wechatPay;\n  var selectedMood = initialEntry?.mood ?? ExpenseMood.none;');
  
  // 2. Inject Mood Selection UI above '记账日期'
  final dateTarget = '                ListTile(\n                  shape: RoundedRectangleBorder(\n                    borderRadius: BorderRadius.circular(18),';
  if (!text.contains(dateTarget)) print("Not found dateTarget!");

  final moodUi = '''                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('这一单的心情状态: \${selectedMood.label} \${selectedMood.emoji}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: ExpenseMood.values.map((m) {
                          final isSelected = selectedMood == m;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: FilterChip(
                              label: Text(m.emoji),
                              selected: isSelected,
                              onSelected: (val) {
                                setModalState(() => selectedMood = m);
                              },
                              selectedColor: m.color.withValues(alpha: 0.2),
                              side: isSelected ? BorderSide(color: m.color, width: 2) : null,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),''';
  text = text.replaceFirst(dateTarget, moodUi);

  // 3. Inject into new LedgerEntry constructor
  final createTarget = '                                tags: parsedTags,\n                                autoCaptured: false,';
  if (!text.contains(createTarget)) print("Not found createTarget!");
  text = text.replaceFirst(createTarget, '                                tags: parsedTags,\n                                mood: selectedMood,\n                                autoCaptured: false,');

  // 4. Inject into copyWith
  final copyTarget = '                          tags: parsedTags,\n                        );';
  if (!text.contains(copyTarget)) print("Not found copyTarget!");
  text = text.replaceFirst(copyTarget, '                          tags: parsedTags,\n                          mood: selectedMood,\n                        );');

  await file.writeAsString(text);
  print('Added Mood Editor UI');
}
