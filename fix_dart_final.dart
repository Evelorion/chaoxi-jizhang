import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  final lines = text.split('\n');
  int index1 = lines.indexWhere((l) => l.contains('subtitle: Text("分类为:'));
  if (index1 != -1) {
    if (lines[index1+1].contains('自动打标')) {
      lines[index1] = r'                    subtitle: Text("分类为: ${category.name}\n自动打标: ${rule.autoTags.join('\'' , '\'')}"),';
      lines.removeAt(index1 + 1);
    }
  }

  int index2 = lines.indexWhere((l) => l.contains('child: Text(\'快来添加你的微信'));
  if (index2 != -1) {
    if (lines[index2+1].trim().isEmpty && lines[index2+2].contains('添加期初余额后')) {
      lines[index2] = r"                child: Text('快来添加你的微信、支付宝或者银行卡资产吧！\n\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。', style: GoogleFonts.plusJakartaSans(color: const Color(0xFF60708A), height: 1.5), textAlign: TextAlign.center),";
      lines.removeAt(index2 + 1); // empty line
      lines.removeAt(index2 + 1); // the rest
    }
  }

  await file.writeAsString(lines.join('\n'));
  print("FINALLY DART FIXED");
}
