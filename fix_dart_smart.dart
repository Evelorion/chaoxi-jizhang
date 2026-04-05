import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  // Find line by line
  final lines = text.split('\n');
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].contains('subtitle: Text("分类为: \${category.name}\\') && i + 1 < lines.length && lines[i+1].contains('自动打标: \${rule.autoTags.')) {
      lines[i] = '                    subtitle: Text("分类为: \${category.name}\\\\n自动打标: \${rule.autoTags.join(\\' , \\')}"),';
      lines.removeAt(i + 1);
    }
  }

  text = lines.join('\n');
  
  // Now for the second one, just replace all '\r\n\r\n添加期初余额后' with '\\n\\n添加期初余额后'
  text = text.replaceAll('\r\n\r\n添加期初余额后', '\\n\\n添加期初余额后');
  text = text.replaceAll('\n\n添加期初余额后', '\\n\\n添加期初余额后');
  text = text.replaceAll('资产吧！\r\n', '资产吧！');
  text = text.replaceAll('资产吧！\n', '资产吧！');

  await file.writeAsString(text);
  print("Done");
}
