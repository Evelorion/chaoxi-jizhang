import 'dart:io';

void main() async {
  final file = File('lib/src/ui_predict_cards.dart');
  var text = await file.readAsString();
  text = text.replaceAll(r'\${', r'${');
  text = text.replaceAll(r'\$', r'$');
  await file.writeAsString(text);
  print("Fixed ui_predict_cards.dart backslashes");
}
