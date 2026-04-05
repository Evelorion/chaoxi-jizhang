import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  final moodEnum = '''
enum ExpenseMood {
  none('无心情', '😐', Color(0xFF9E9E9E)),
  angry('冲动解压', '😡', Color(0xFFF44336)),
  happy('开心庆祝', '🎉', Color(0xFFFF9800)),
  tired('疲惫犒劳', '☕', Color(0xFF795548)),
  sad('emo抚慰', '🌧️', Color(0xFF2196F3)),
  chill('平静松弛', '🧘', Color(0xFF009688));

  final String label;
  final String emoji;
  final Color color;
  const ExpenseMood(this.label, this.emoji, this.color);
}

class LedgerEntry {''';

  text = text.replaceAll('class LedgerEntry {', moodEnum);

  text = text.replaceAll(
    'this.locationInfo = \'\',',
    'this.locationInfo = \'\',\n    this.mood = ExpenseMood.none,'
  );

  text = text.replaceAll(
    'final String locationInfo;',
    'final String locationInfo;\n  final ExpenseMood mood;'
  );

  text = text.replaceAll(
    'String? locationInfo,',
    'String? locationInfo,\n    ExpenseMood? mood,'
  );

  text = text.replaceAll(
    'locationInfo: locationInfo ?? this.locationInfo,',
    'locationInfo: locationInfo ?? this.locationInfo,\n      mood: mood ?? this.mood,'
  );

  text = text.replaceAll(
    '\'locationInfo\': locationInfo,',
    '\'locationInfo\': locationInfo,\n    \'mood\': mood.name,'
  );

  text = text.replaceAll(
    'locationInfo: json[\'locationInfo\'] as String? ?? \'\',',
    'locationInfo: json[\'locationInfo\'] as String? ?? \'\',\n    mood: ExpenseMood.values.firstWhere((e) => e.name == json[\'mood\'], orElse: () => ExpenseMood.none),'
  );

  await file.writeAsString(text);
  print('Added ExpenseMood to LedgerEntry');
}
