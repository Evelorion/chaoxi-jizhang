import re
with open("lib/src/ui_extensions.dart", "r", encoding="utf-8") as f:
    text = f.read()

# Fix literal newline split in category
text = re.sub(
    r'subtitle:\s*Text\("分类为:\s*\$\{category\.name\}\\\n自动打标:\s*\$\{rule\.autoTags\.join\(\', \'\)\}"\),',
    r'subtitle: Text("分类为: ${category.name}\\n自动打标: ${rule.autoTags.join(\', \')}"),',
    text
)

# Fix literal newline split in asset account view (lines 212-214) 
# child: Text('快来添加你的微信、支付宝或者银行卡资产吧！\n\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。', style: GoogleFonts.plusJakartaSans(color: const Color(0xFF60708A), height: 1.5), textAlign: TextAlign.center),
text = re.sub(
    r"child:\s*Text\('快来添加你的微信、支付宝或者银行卡资产吧！\n\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。',",
    r"child: Text('快来添加你的微信、支付宝或者银行卡资产吧！\\n\\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。',",
    text
)

with open("lib/src/ui_extensions.dart", "w", encoding="utf-8") as f:
    f.write(text)
print("Done")
