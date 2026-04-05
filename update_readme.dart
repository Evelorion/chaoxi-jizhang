import 'dart:io';

void main() async {
  final file = File('README.md');
  var text = await file.readAsString();

  final newChangelog = '''
## 🎉 最新智能化升级 (AI Evolution)

本项目现已全面接入本地 AI 与离线智能分析系统：
- **纯血离线 STT 录音引擎与自然语义提取 (NLP)**：支持无唤醒直接按住系统浮窗收录人声。一句“昨天在全家买水花了5块”，APP将通过纯本地极速正则表达式，瞬间提纯：日期（昨天）、商户（全家）、分类（餐饮）、金额（5.00）并一键极简入账。
- **动态防刺客订阅雷达 (Subscription Radar)**：底层算法全局扫描聚类长达 120 天的历史流水，自动在月底弹窗预警那些躲在暗处的会员包月卡、音乐连续包月，极致护住钱包！
- **天气气候级算账预测 (Burn-rate Predictor)**：结合当前的消费频率频次，将预算进度转化为天气的拟人表达（“照这个造法，餐饮预算将在 3 天后阵亡...”）。
- **极度治愈的情绪消费热图 (Mood Analysis)**：在洞察页面新加入情感颗粒度，你可以在极速记账时打上 🤡🤬👻 等心情状态，在月底一揽子分析自己开心与烦躁时的花钱比例。
- **重建极致顺滑的资金池模块**：引入原生级别的果冻弹性特效，所有期初账户支持重新编辑余额更正，不绑架你的任何失误。

## 现在能做什么
''';

  text = text.replaceFirst('## 现在能做什么\n', newChangelog);

  await file.writeAsString(text);
  print('Updated README.md');
}
