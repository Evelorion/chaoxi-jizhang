import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  final assetViewStart = text.indexOf('class AssetAccountsView extends ConsumerStatefulWidget');
  if (assetViewStart == -1) {
    print('Could not find AssetAccountsView');
    return;
  }

  // Find where to inject Tween inside AssetAccountsView definition
  final glassCardIndex = text.indexOf('return _GlassCard(', assetViewStart);
  
  if (glassCardIndex != -1) {
    text = text.replaceFirst('return _GlassCard(\n                  child: ListTile(', 
'''return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.8, end: 1.0),
                  duration: Duration(milliseconds: 300 + (index * 100).clamp(0, 500)),
                  curve: Curves.elasticOut,
                  builder: (context, scale, child) {
                    return Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: (scale - 0.8) / 0.2,
                        child: child,
                      ),
                    );
                  },
                  child: _GlassCard(
                    child: InkWell(
                      onTap: () => _editAccount(index, acc),
                      borderRadius: BorderRadius.circular(16),
                      child: ListTile(''', glassCardIndex);
  }

  final listViewEnd = text.indexOf('              },\n            ),', glassCardIndex);
  if (listViewEnd != -1) {
    final blockToReplace = '''                    ),
                  ),
                );
              },
            ),''';
    text = text.replaceFirst(blockToReplace, '''                    ),
                    ),
                  ),
                  ),
                );
              },
            ),''', listViewEnd - 100);
  }

  await file.writeAsString(text);
  print('Fixed AssetAccountsView via index');
}
