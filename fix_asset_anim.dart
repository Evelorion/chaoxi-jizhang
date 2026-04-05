import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  // 1. Change _AssetEditorSheet
  text = text.replaceFirst(
    'class _AssetEditorSheet extends StatefulWidget {\n  const _AssetEditorSheet();',
    'class _AssetEditorSheet extends StatefulWidget {\n  const _AssetEditorSheet({this.initialAccount, super.key});\n  final AssetAccount? initialAccount;'
  );

  // 2. Init controllers
  text = text.replaceFirst(
    'class _AssetEditorSheetState extends State<_AssetEditorSheet> {\n  final _nameCtrl = TextEditingController();\n  final _amountCtrl = TextEditingController();\n  AssetType _type = AssetType.wechat;',
    '''class _AssetEditorSheetState extends State<_AssetEditorSheet> {
  late final TextEditingController _nameCtrl = TextEditingController(text: widget.initialAccount?.name ?? '');
  late final TextEditingController _amountCtrl = TextEditingController(text: widget.initialAccount?.initialBalance.toString() ?? '');
  late AssetType _type = widget.initialAccount?.type ?? AssetType.wechat;
'''
  );

  // 3. title
  text = text.replaceFirst(
    'Text(\'新增资金池\', style: GoogleFonts.spaceGrotesk(fontSize: 20, fontWeight: FontWeight.w700)),',
    'Text(widget.initialAccount == null ? \'新增资金池\' : \'修改资金池 (重设起止余额)\', style: GoogleFonts.spaceGrotesk(fontSize: 20, fontWeight: FontWeight.w700)),'
  );

  // 4. save
  text = text.replaceFirst(
    '''              final acc = AssetAccount(id: const Uuid().v4(), name: _nameCtrl.text.trim(), type: _type, initialBalance: amt);
              Navigator.pop(context, acc);''',
    '''              final acc = AssetAccount(id: widget.initialAccount?.id ?? const Uuid().v4(), name: _nameCtrl.text.trim(), type: _type, initialBalance: amt);
              Navigator.pop(context, acc);'''
  );

  // 5. _editAccount
  text = text.replaceFirst(
    '''  void _addAccount() async {''',
    '''  void _editAccount(int index, AssetAccount acc) async {
    final updatedAcc = await showModalBottomSheet<AssetAccount>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssetEditorSheet(initialAccount: acc),
    );
    if (updatedAcc != null) {
      setState(() => _accounts[index] = updatedAcc);
      _save();
    }
  }

  void _addAccount() async {'''
  );

  // 6. Wrap items with InkWell and Animation
  final buildItemStartInfo = '''                return _GlassCard(
                  child: ListTile(''';
  final buildItemReplaceInfo = '''                return TweenAnimationBuilder<double>(
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
                      child: ListTile(''' ;
  text = text.replaceFirst(buildItemStartInfo, buildItemReplaceInfo);

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

  await file.writeAsString(text);
  print('Patched AssetAccountsView');
}
