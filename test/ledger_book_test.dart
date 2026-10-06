import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jier/src/app.dart';

class _FailingVaultRepository extends LedgerVaultRepository {
  const _FailingVaultRepository() : super(const VaultCryptoBridge());

  @override
  Future<bool> vaultExists() async => false;

  @override
  Future<void> save(LedgerBook book, String passphrase) async {
    throw const FileSystemException('storage full');
  }
}

void main() {
  test('legacy vault settings default biometric unlock to false', () {
    final settings = VaultSettings.fromJson(const {
      'confidentialModeEnabled': true,
      'maskAmounts': true,
      'quickLockOnBackground': true,
      'allowScreenshots': false,
    });

    expect(settings.biometricUnlockEnabled, isFalse);
    expect(settings.autoCaptureEnabled, isTrue);
    expect(settings.defaultExpenseCategoryId, 'daily');
  });

  test('new vault starts empty without seeded records', () {
    final book = LedgerBook.empty(true);

    expect(book.entries, isEmpty);
    expect(book.budgets, isEmpty);
    expect(book.goals, isEmpty);
    expect(book.subscriptions, isEmpty);
    expect(book.settings.confidentialModeEnabled, isTrue);
    expect(book.settings.allowScreenshots, isTrue);
  });

  test('vault creation stays on setup when saving fails', () async {
    final controller = LedgerController(
      const _FailingVaultRepository(),
      const AndroidAutoCaptureBridge(),
      const AndroidWindowPrivacyBridge(),
      BiometricVaultBridge(),
    );
    await controller.initialize();
    await controller.createVault(
      passphrase: 'test-passphrase',
      confidentialModeEnabled: true,
    );
    expect(controller.state.onboardingRequired, isTrue);
    expect(controller.state.book, isNull);
    expect(controller.state.canShowShell, isFalse);
    expect(controller.state.errorMessage, contains('保存失败'));
    controller.dispose();
  });

  test('legacy seeded content is removed while real records stay', () {
    final legacyBook = LedgerBook.seeded(false);
    final realEntry = LedgerEntry(
      id: 'real-entry',
      title: '真实午餐',
      merchant: '小店',
      note: '用户手动记账',
      amount: 28,
      type: EntryType.expense,
      categoryId: 'food',
      channel: PaymentChannel.wechatPay,
      occurredAt: DateTime(2026, 3, 22, 12, 30),
      tags: const ['真实'],
      autoCaptured: false,
      sourceLabel: '',
    );

    final mixedBook = legacyBook.copyWith(
      entries: [...legacyBook.entries, realEntry],
    );

    final cleaned = mixedBook.withoutLegacySeedData();

    expect(cleaned.entries, hasLength(1));
    expect(cleaned.entries.single.id, 'real-entry');
    expect(cleaned.budgets, isEmpty);
    expect(cleaned.goals, isEmpty);
    expect(cleaned.subscriptions, isEmpty);
  });

  test(
    'shopping payments keep shopping title while source stays payment app',
    () {
      final book = LedgerBook.empty(false).copyWith(
        entries: [
          LedgerEntry(
            id: 'auto-1',
            title: '微信付款 · 山野小铺',
            merchant: '山野小铺',
            note: '自动记账',
            amount: 129,
            type: EntryType.expense,
            categoryId: 'shopping',
            channel: PaymentChannel.wechatPay,
            occurredAt: DateTime(2026, 3, 22, 13, 20),
            tags: const ['淘宝', '平台支付'],
            autoCaptured: true,
            sourceLabel: '微信',
          ),
        ],
      );

      final normalized = book.normalizeShoppingAutoCaptureTitles();

      expect(normalized.entries.single.title, '淘宝付款 · 山野小铺');
      expect(normalized.entries.single.sourceLabel, '微信');
      expect(buildEntryMetaLine(normalized.entries.single), contains('来源：微信'));
    },
  );

  test(
    'legacy auto-captured entries backfill counterparty names from notes',
    () {
      final book = LedgerBook.empty(false).copyWith(
        entries: [
          LedgerEntry(
            id: 'auto-2',
            title: '微信转账收入',
            merchant: '未识别对象',
            note: '微信名字：夏曦晨光\n来源：微信',
            amount: 88,
            type: EntryType.income,
            categoryId: 'shopping',
            channel: PaymentChannel.wechatPay,
            occurredAt: DateTime(2026, 3, 22, 14, 0),
            tags: const ['转账收入'],
            autoCaptured: true,
            sourceLabel: '微信',
          ),
        ],
      );

      final normalized = book.backfillAutoCaptureCounterpartyNames();
      final entry = normalized.entries.single;

      expect(entry.counterpartyName, '夏曦晨光');
      expect(entry.title, contains('夏曦晨光'));
      expect(entry.note, contains('付款人：夏曦晨光'));
      expect(buildEntryMetaLine(entry), contains('付款人：夏曦晨光'));
    },
  );

  test('search matches counterparty names and serialized json keeps field', () {
    final entry = LedgerEntry(
      id: 'auto-3',
      title: '微信转账支出 · 李四',
      merchant: '未识别对象',
      counterpartyName: '李四',
      note: '收款方：李四',
      amount: 66,
      type: EntryType.expense,
      categoryId: 'shopping',
      channel: PaymentChannel.wechatPay,
      occurredAt: DateTime(2026, 3, 22, 15, 0),
      tags: const ['转账支出'],
      autoCaptured: true,
      sourceLabel: '微信',
    );

    expect(matchesTransactionQuery(entry, '李四'), isTrue);
    expect(entry.toJson()['counterpartyName'], '李四');
  });

  test('utc auto-captured entries migrate to local device time', () {
    final utcMoment = DateTime.utc(2026, 3, 23, 4, 30);
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        LedgerEntry(
          id: 'auto-utc',
          title: '微信付款',
          merchant: '小店',
          note: '自动记账',
          amount: 20,
          type: EntryType.expense,
          categoryId: 'food',
          channel: PaymentChannel.wechatPay,
          occurredAt: utcMoment,
          tags: const ['自动'],
          autoCaptured: true,
          sourceLabel: '微信',
          autoPostedAtMillis: utcMoment.millisecondsSinceEpoch,
        ),
      ],
    );

    final migrated = book.migrateAutoCapturedUtcTimes();
    final entry = migrated.entries.single;

    expect(entry.occurredAt.isUtc, isFalse);
    expect(
      entry.occurredAt.millisecondsSinceEpoch,
      utcMoment.millisecondsSinceEpoch,
    );
    expect(entry.autoPostedAtMillis, utcMoment.millisecondsSinceEpoch);
  });

  test('period membership and search include named period', () {
    final period = LedgerPeriod(
      id: 'travel-period',
      name: '日本旅行',
      startAt: DateTime(2026, 4, 1, 0, 0),
      endAt: DateTime(2026, 4, 10, 0, 0),
      note: '京都和大阪',
    );
    final entry = LedgerEntry(
      id: 'travel-entry',
      title: '机票',
      merchant: '东方航空',
      note: '春季旅行',
      amount: 1880,
      type: EntryType.expense,
      categoryId: 'travel',
      channel: PaymentChannel.alipay,
      occurredAt: DateTime(2026, 4, 2, 9, 30),
      tags: const ['出行'],
      autoCaptured: false,
      sourceLabel: '',
    );
    final book = LedgerBook.empty(
      false,
    ).copyWith(periods: [period], entries: [entry]);

    expect(periodForEntry(book, entry)?.name, '日本旅行');
    expect(entryFallsWithinPeriod(entry, period), isTrue);
    expect(matchesTransactionQuery(entry, '日本旅行', book: book), isTrue);
    expect(book.toJson()['periods'], isNotEmpty);
  });
  test(
    'auto-capture category prefers name and merchant analysis over fallback',
    () {
      final book = LedgerBook.empty(false);
      final familyCapture = AutoCaptureRecord(
        id: 'capture-family',
        title: '微信转账支出 · 妈妈',
        merchant: '未识别对象',
        counterpartyName: '妈妈',
        rawBody: '你向妈妈转账',
        scenario: 'transferPayment',
        detailSummary: '收款方：妈妈',
        amount: 66,
        entryType: EntryType.expense,
        channel: PaymentChannel.wechatPay,
        source: CaptureSource.wechat,
        capturedAt: DateTime(2026, 3, 23, 18, 30),
        postedAtMillis: DateTime(2026, 3, 23, 18, 30).millisecondsSinceEpoch,
        confidence: 0.92,
        defaultCategoryId: 'daily',
        profileId: 0,
        mergeKey: 'family',
        relatedSources: const [],
      );
      final shoppingCapture = AutoCaptureRecord(
        id: 'capture-shopping',
        title: '淘宝付款 · 山野小铺',
        merchant: '山野小铺',
        rawBody: '淘宝订单支付成功',
        scenario: 'platformPayment',
        detailSummary: '店铺：山野小铺',
        amount: 129,
        entryType: EntryType.expense,
        channel: PaymentChannel.wechatPay,
        source: CaptureSource.wechat,
        capturedAt: DateTime(2026, 3, 23, 18, 35),
        postedAtMillis: DateTime(2026, 3, 23, 18, 35).millisecondsSinceEpoch,
        confidence: 0.95,
        defaultCategoryId: 'daily',
        profileId: 0,
        mergeKey: 'shopping',
        relatedSources: const [CaptureSource.taobao],
      );

      expect(
        inferAutoCaptureCategoryId(book: book, capture: familyCapture).$1,
        'family',
      );
      expect(
        inferAutoCaptureCategoryId(book: book, capture: shoppingCapture).$1,
        'shopping',
      );
    },
  );

  test('local AI uses only current month and never includes private notes', () {
    final current = LedgerEntry(
      id: 'current',
      title: '午餐\n外卖',
      merchant: '小店',
      note: '私人备注不应进入 AI 提示词',
      amount: 28,
      type: EntryType.expense,
      categoryId: 'food',
      channel: PaymentChannel.wechatPay,
      occurredAt: DateTime(2026, 10, 2),
      autoCaptured: false,
      sourceLabel: '',
    );
    final old = current.copyWith(
      id: 'old',
      title: '旧账',
      amount: 9999,
      occurredAt: DateTime(2026, 9, 2),
    );
    final book = LedgerBook.empty(false).copyWith(entries: [old, current]);
    final prompt = buildLocalAiPrompt(book, now: DateTime(2026, 10, 6));
    expect(prompt, contains('支出28.00元'));
    expect(prompt, contains('午餐 外卖'));
    expect(prompt, isNot(contains('私人备注')));
    expect(prompt, isNot(contains('9999')));
  });

  test(
    'local AI category output is limited to valid category and entry type',
    () {
      AutoCaptureRecord capture(String id, EntryType type) => AutoCaptureRecord(
        id: id,
        title: '支付',
        merchant: '小店',
        rawBody: '支付成功',
        scenario: 'merchantPayment',
        detailSummary: '',
        amount: 10,
        entryType: type,
        channel: PaymentChannel.wechatPay,
        source: CaptureSource.wechat,
        capturedAt: DateTime(2026, 10, 6),
        postedAtMillis: DateTime(2026, 10, 6).millisecondsSinceEpoch,
        confidence: 0.9,
        defaultCategoryId: 'daily',
        profileId: 0,
        mergeKey: 'key',
        relatedSources: const [],
      );
      final batch = [
        capture('expense', EntryType.expense),
        capture('income', EntryType.income),
      ];
      final parsed = parseLocalAiCategories(
        '结果：{"0":"food","1":"shopping"}',
        batch,
      );
      expect(parsed, {'expense': 'food'});
      expect(parseLocalAiCategories('不是 JSON', batch), isEmpty);
    },
  );

  test('local AI preference survives vault settings serialization', () {
    final settings = LedgerBook.empty(false).settings.copyWith(
      localAiModelId: 'qwen3-17b-q4',
      autoAiCaptureEnabled: true,
    );
    final restored = VaultSettings.fromJson(settings.toJson());
    expect(restored.localAiModelId, 'qwen3-17b-q4');
    expect(restored.autoAiCaptureEnabled, isTrue);
  });

  test('local AI question retrieves merchant history across months', () {
    LedgerEntry entry(
      String id,
      String merchant,
      DateTime date,
      double amount,
    ) => LedgerEntry(
      id: id,
      title: '咖啡',
      merchant: merchant,
      note: '不可展示的私人备注',
      amount: amount,
      type: EntryType.expense,
      categoryId: 'food',
      channel: PaymentChannel.wechatPay,
      occurredAt: date,
      autoCaptured: false,
      sourceLabel: '',
    );
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        entry('old', '瑞幸', DateTime(2026, 9, 12), 22),
        entry('new', '瑞幸', DateTime(2026, 10, 3), 25),
        entry('other', '别的店', DateTime(2026, 10, 4), 99),
      ],
    );
    final history = buildLocalAiQuestionPrompt(
      book,
      '上次在瑞幸消费是什么时候？',
      now: DateTime(2026, 10, 6),
    );
    expect(history, contains('2026-10-03'));
    expect(history, contains('2026-09-12'));
    expect(history, isNot(contains('99.00元')));
    expect(history, isNot(contains('私人备注')));
    final monthly = buildLocalAiQuestionPrompt(
      book,
      '这个月在瑞幸花了多少？',
      now: DateTime(2026, 10, 6),
    );
    expect(monthly, contains('支出25.00元'));
    expect(monthly, isNot(contains('2026-09-12')));
    final september = buildLocalAiQuestionPrompt(
      book,
      '9月买了什么？',
      now: DateTime(2026, 10, 6),
    );
    expect(september, contains('2026-09-12'));
    expect(september, isNot(contains('2026-10-03')));
    final yesterday = buildLocalAiQuestionPrompt(
      book,
      '昨天消费了什么？',
      now: DateTime(2026, 10, 4),
    );
    expect(yesterday, contains('2026-10-03'));
    expect(yesterday, isNot(contains('2026-09-12')));
  });
}
