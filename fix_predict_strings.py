import re
with open("lib/src/ui_predict_cards.dart", "r", encoding="utf-8") as f:
    text = f.read()

text = text.replace(r'\${', '${')
text = text.replace(r'\$', '$')

with open("lib/src/ui_predict_cards.dart", "w", encoding="utf-8") as f:
    f.write(text)
print("Fixed ui_predict_cards.dart backslashes")
