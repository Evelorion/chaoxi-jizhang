import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  // 1. Revert the broken SettingsCustomRulesView block
  final brokenBlock = '''                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.8, end: 1.0),
                  duration: Duration(milliseconds: 300 + (index * 100).clamp(0, 500)),
                  curve: Curves.elasticOut,
                  builder: (context, scale, child) {
                    return Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: (scale - 0.8) / 0.2, // 0.8->0, 1.0->1.0
                        child: child,
                      ),
                    );
                  },
                  child: _GlassCard(
                    child: InkWell(
                      onTap: () => _editAccount(index, acc),
                      borderRadius: BorderRadius.circular(16),
                      child: ListTile(''';

  text = text.replaceFirst(brokenBlock, '''                return _GlassCard(
                  child: ListTile(''');

  final brokenEnd = '''                    ),
                  ),
                );
              },
            ),''';
  
  // Actually, wait, let's just find the exact text in my previous view_file.
  // Lines 100-107:
  final actualBrokenEnd = '''                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFC44536)),
                      onPressed: () => _deleteRule(index),
                    ),
                  ),
                );
              },
            ),''';

  // My previous replace replaced:
  /*
  // 7. tile end
  text = text.replaceFirst(
'''                      ),
                    ),
                  ),
                );
              },
            ),''', 
'''                      ),
                    ),
                  ),
                  ),
                );
              },
            ),'''
  );
  */
  // So the end of Rule view was NOT affected because `text.replaceFirst` only replaced the first occurrence!
  // Wait, `replaceFirst` replaces the FIRST occurrence.
  // The first occurrence of `return _GlassCard(...)` was in RulesView. So THAT got messed up.
  // The first occurrence of `tile end` was ALSO in RulesView ? No, let's see.

  await file.writeAsString(text);
  print('Fixed first block');
}
