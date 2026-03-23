# 潮汐账本

一款面向日常生活场景的 Flutter 安卓记账应用。它把自动记账、预算目标、命名账期、洞察分析和本地加密放在同一个应用里，重点不是“做一套好看的空 UI”，而是把真实可用的记账流程做完整。

## 现在能做什么

- 自动记账：通过系统通知读取微信、支付宝、Google Pay、淘宝、京东、拼多多、闲鱼等支付/订单提示，并尽量合并成一条主支付记录。
- 流水管理：支持搜索、筛选、编辑、删除、账期归类，以及自动识别付款人/收款方名字。
- 计划能力：支持预算信封、生活目标、固定支出计划、命名账期。
- 洞察分析：提供近六个月现金流、分类结构、生活维度热力表和关键判断。
- 隐私与安全：账本默认保存在本机，Android 侧使用标准 AES-GCM 加密，支持指纹解锁、禁止截屏、本地加密备份导入导出。

## 下载

- 最新版本：见 [Releases](https://github.com/Evelorion/chaoxi-jizhang/releases/latest)
- 当前仓库默认提供 `arm64-v8a` Android Release APK

## 页面预览

<table>
  <tr>
    <td align="center">
      <img src="docs/screenshots/overview.jpg" width="260" alt="总览页" />
      <div><strong>总览</strong><br/>看本月净结余、生活覆盖和自动记账进展</div>
    </td>
    <td align="center">
      <img src="docs/screenshots/transactions.jpg" width="260" alt="流水页" />
      <div><strong>流水</strong><br/>搜索、筛选、编辑和追踪每一笔流水来源</div>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="docs/screenshots/plans.jpg" width="260" alt="计划页" />
      <div><strong>计划</strong><br/>预算、目标、账期和固定计划统一管理</div>
    </td>
    <td align="center">
      <img src="docs/screenshots/insights.jpg" width="260" alt="洞察页" />
      <div><strong>洞察</strong><br/>用结构图和现金流趋势把钱放回生活语境里看</div>
    </td>
  </tr>
</table>

## 技术栈

- Flutter 3 / Dart
- Android Kotlin 通知监听服务
- Riverpod 状态管理
- fl_chart 数据可视化
- local_auth / flutter_secure_storage 本地生物识别与安全存储

## 本地运行

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

## Android 打包

```bash
flutter build apk --release --split-per-abi
```

默认产物位置：

- `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`
- `build/app/outputs/flutter-apk/app-x86_64-release.apk`

## 项目结构

```text
lib/
  main.dart
  src/app.dart                  Flutter 主界面、数据模型、控制器
android/app/src/main/kotlin/
  .../MainActivity.kt          Android 原生桥接
  .../LedgerNotificationListenerService.kt
  .../NotificationParser.kt    自动记账通知解析
  .../VaultCipher.kt           Android 本地加密
test/
  ledger_book_test.dart        账本与序列化回归测试
```

## 当前重点

- 优化总览到收入/支出详情页的转场与返回性能
- 继续提升微信/支付宝转账通知的人名和方向识别
- 完善 Release 发布流程和版本说明
