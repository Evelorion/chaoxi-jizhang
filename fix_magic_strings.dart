import 'dart:io';

void main() async {
  final file = File('lib/src/ui_magic_bar.dart');
  var text = await file.readAsString();
  text = text.replaceAll(r'\${', r'${');
  await file.writeAsString(text);
  print("Fixed ui_magic_bar.dart backslashes");
}
