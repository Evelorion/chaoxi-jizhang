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
    final query = buildLedgerAiQuery(
      book,
      '这个月消费了多少？',
      now: DateTime(2026, 10, 6),
    );
    expect(query.entryIds, ['current']);
    expect(query.prompt, contains('支出28.00元'));
    expect(query.prompt, contains('午餐 外卖'));
    expect(query.prompt, isNot(contains('私人备注')));
    expect(query.prompt, isNot(contains('9999')));
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

  test('merchant payments are not all filed under family', () {
    // 回归用例：解析结果里的“商家：麦当劳”曾经命中家庭分类的关键词“家”，
    // 导致每一笔自动记账都被记成“家庭”。
    AutoCaptureRecord capture({
      required String id,
      required String title,
      required String merchant,
      String detail = '',
      String rawBody = '支付成功',
      String defaultCategoryId = 'daily',
    }) => AutoCaptureRecord(
      id: id,
      title: title,
      merchant: merchant,
      counterpartyName: '',
      rawBody: rawBody,
      scenario: 'merchantPayment',
      detailSummary: detail.isEmpty ? '' : '商家：$detail',
      amount: 35,
      entryType: EntryType.expense,
      channel: PaymentChannel.wechatPay,
      source: CaptureSource.wechat,
      capturedAt: DateTime(2026, 10, 6),
      postedAtMillis: DateTime(2026, 10, 6).millisecondsSinceEpoch,
      confidence: 0.95,
      defaultCategoryId: defaultCategoryId,
      profileId: 0,
      mergeKey: id,
      relatedSources: const [],
    );
    final book = LedgerBook.empty(false);

    expect(
      inferAutoCaptureCategoryId(
        book: book,
        capture: capture(
          id: 'mcd',
          title: '微信付款 · 麦当劳',
          merchant: '麦当劳',
          detail: '麦当劳',
          defaultCategoryId: 'food',
        ),
      ).$1,
      'food',
    );
    expect(
      inferAutoCaptureCategoryId(
        book: book,
        capture: capture(
          id: 'shop',
          title: '支付宝付款 · 某某小店',
          merchant: '某某小店',
          detail: '某某小店',
        ),
      ).$1,
      'daily',
    );
    // 真的是给家人转账时才归到家庭。
    expect(
      inferAutoCaptureCategoryId(
        book: book,
        capture: capture(
          id: 'mom',
          title: '微信转账支出 · 妈妈',
          merchant: '未识别对象',
          rawBody: '你向妈妈转账',
        ),
      ).$1,
      'family',
    );
  });

  test('AI generated entry fields are validated before use', () {
    // 只接受该收支类型下的合法分类，其它一律丢掉。
    LedgerEntry entry(String id, EntryType type) => LedgerEntry(
      id: id,
      title: '微信付款 · 某某小店',
      merchant: '某某小店',
      note: '微信支付 付款成功 30.00 元',
      amount: 30,
      type: type,
      categoryId: 'daily',
      channel: PaymentChannel.wechatPay,
      occurredAt: DateTime(2026, 10, 6),
      autoCaptured: true,
      sourceLabel: '微信',
    );
    final batch = [
      entry('a', EntryType.expense),
      entry('b', EntryType.income),
    ];

    final parsed = parseLocalAiEntryCategories(
      '结果：{"0":"food","1":"shopping"}',
      batch,
    );
    // shopping 是支出分类，不能给收入用
    expect(parsed, {'a': 'food'});
    expect(parseLocalAiEntryCategories('不是 JSON', batch), isEmpty);
    expect(parseLocalAiEntryCategories('{"0":"不存在的分类"}', batch), isEmpty);
  });

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
    final history = buildLedgerAiQuery(
      book,
      '上次在瑞幸消费是什么时候？',
      now: DateTime(2026, 10, 6),
    );
    expect(history.entryIds, containsAll(['old', 'new']));
    expect(history.prompt, contains('2026-10-03'));
    expect(history.prompt, contains('2026-09-12'));
    expect(history.prompt, isNot(contains('99.00元')));
    expect(history.prompt, isNot(contains('私人备注')));
    final monthly = buildLedgerAiQuery(
      book,
      '这个月在瑞幸花了多少？',
      now: DateTime(2026, 10, 6),
    );
    expect(monthly.entryIds, ['new']);
    expect(monthly.prompt, contains('支出25.00元'));
    expect(monthly.prompt, isNot(contains('2026-09-12')));
    final september = buildLedgerAiQuery(
      book,
      '9月买了什么？',
      now: DateTime(2026, 10, 6),
    );
    expect(september.entryIds, ['old']);
    expect(september.prompt, contains('2026-09-12'));
    expect(september.prompt, isNot(contains('2026-10-03')));
    final yesterday = buildLedgerAiQuery(
      book,
      '昨天消费了什么？',
      now: DateTime(2026, 10, 4),
    );
    expect(yesterday.entryIds, ['new']);
    expect(yesterday.prompt, contains('2026-10-03'));
    expect(yesterday.prompt, isNot(contains('2026-09-12')));
  });

  test('ledger chat remembers the previous day filter and payer details', () {
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        LedgerEntry(
          id: 'today',
          title: '午餐',
          merchant: '小馆',
          counterpartyName: '王先生',
          note: '不应传给模型的私人备注',
          amount: 32,
          type: EntryType.expense,
          categoryId: 'food',
          channel: PaymentChannel.wechatPay,
          occurredAt: DateTime(2026, 10, 6, 12),
          autoCaptured: false,
          sourceLabel: '',
        ),
        LedgerEntry(
          id: 'older',
          title: '早餐',
          merchant: '早餐店',
          note: '',
          amount: 12,
          type: EntryType.expense,
          categoryId: 'food',
          channel: PaymentChannel.alipay,
          occurredAt: DateTime(2026, 10, 5, 8),
          autoCaptured: false,
          sourceLabel: '',
        ),
      ],
    );
    final first = buildLedgerAiQuery(
      book,
      '今天消费了多少？',
      now: DateTime(2026, 10, 6, 18),
    );
    expect(first.entryIds, ['today']);
    expect(first.prompt, contains('支出32.00元'));
    final followUp = buildLedgerAiQuery(
      book,
      '付款方是谁？',
      now: DateTime(2026, 10, 6, 18),
      previousEntryIds: first.entryIds,
      history: [
        LedgerAiMessage(
          role: 'assistant',
          text: '今天支出32元。',
          createdAt: DateTime(2026, 10, 6, 18),
        ),
      ],
    );
    expect(followUp.entryIds, ['today']);
    expect(followUp.prompt, contains('王先生'));
    expect(followUp.prompt, contains('今天支出32元'));
    expect(followUp.prompt, isNot(contains('早餐店')));
    expect(followUp.prompt, isNot(contains('私人备注')));
  });

  test('encrypted book serialization preserves chat memory', () {
    final book = LedgerBook.empty(false).copyWith(
      aiMessages: [
        LedgerAiMessage(
          role: 'user',
          text: '今天消费多少？',
          createdAt: DateTime(2026, 10, 6, 10),
        ),
      ],
      aiFocusEntryIds: ['entry-one'],
    );
    final restored = LedgerBook.fromJson(book.toJson());
    expect(restored.aiMessages.single.text, '今天消费多少？');
    expect(restored.aiFocusEntryIds, ['entry-one']);
  });

  test('local AI turns a question into a query plan, not a ledger dump', () {
    LedgerEntry entry(
      String id,
      String merchant,
      String categoryId,
      DateTime date,
      double amount,
    ) => LedgerEntry(
      id: id,
      title: '午餐',
      merchant: merchant,
      note: '',
      amount: amount,
      type: EntryType.expense,
      categoryId: categoryId,
      channel: PaymentChannel.wechatPay,
      occurredAt: date,
      autoCaptured: false,
      sourceLabel: '微信',
    );
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        entry('a', '麦当劳', 'food', DateTime(2026, 9, 10), 30),
        entry('b', '肯德基', 'food', DateTime(2026, 9, 12), 52.4),
        entry('c', '滴滴', 'mobility', DateTime(2026, 9, 15), 40),
        entry('d', '麦当劳', 'food', DateTime(2026, 10, 2), 25),
      ],
    );
    final now = DateTime(2026, 10, 6);

    // 模型输出的是查询条件，而不是账目文本
    final spec = parseLedgerQuerySpec(
      '{"continue_context":false,"intent":"sum","category":"餐饮",'
      '"start_date":"2026-09-01","end_date":"2026-09-30"}',
      now: now,
    );
    expect(spec, isNotNull);
    expect(spec!.intent, 'sum');
    expect(spec.categoryId, 'food');
    expect(spec.startDate, DateTime(2026, 9, 1));

    final result = runLedgerQuery(book, spec, now: now);
    expect(result.empty, isFalse);
    expect(result.text, contains('82.40'));

    // 非法 intent / 不是 JSON 一律拒绝，交给兜底
    expect(parseLedgerQuerySpec('{"intent":"drop_table"}'), isNull);
    expect(parseLedgerQuerySpec('今天花了 82.4 元'), isNull);

    // 追问：继承上一轮，只替换变化的字段
    final followUp = parseLedgerQuerySpec(
      '{"continue_context":true,"intent":"sum","category":"出行"}',
    );
    final merged = followUp!.mergedWith(spec);
    expect(merged.startDate, DateTime(2026, 9, 1));
    expect(merged.endDate, DateTime(2026, 9, 30));
    expect(merged.categoryId, 'mobility');
    expect(runLedgerQuery(book, merged, now: now).text, contains('40.00'));

    // 其它意图也都在本地算
    expect(
      runLedgerQuery(
        book,
        const LedgerQuerySpec(intent: 'top_category'),
        now: now,
      ).text,
      contains('餐饮'),
    );
    expect(
      runLedgerQuery(
        book,
        const LedgerQuerySpec(intent: 'latest'),
        now: now,
      ).entryIds,
      ['d'],
    );
    expect(
      runLedgerQuery(
        book,
        const LedgerQuerySpec(intent: 'count', categoryId: 'food'),
        now: now,
      ).text,
      contains('3笔'),
    );
  });

  test('AI fields are sanitised so nothing is fabricated', () {
    AutoCaptureRecord capture(String id) => AutoCaptureRecord(
      id: id,
      title: '微信付款 · 麦当劳',
      merchant: '麦当劳',
      counterpartyName: '',
      rawBody: '微信支付 付款成功 35.00',
      scenario: 'merchantPayment',
      detailSummary: '商家：麦当劳',
      amount: 35,
      entryType: EntryType.expense,
      channel: PaymentChannel.wechatPay,
      source: CaptureSource.wechat,
      capturedAt: DateTime(2026, 10, 6),
      postedAtMillis: DateTime(2026, 10, 6).millisecondsSinceEpoch,
      confidence: 0.9,
      defaultCategoryId: 'food',
      profileId: 0,
      mergeKey: id,
      relatedSources: const [],
    );
    final batch = [capture('a')];

    // 模型把商家名抄成付款方 → 必须丢掉，宁可为空也不编
    final copied = parseAiCaptureFields(
      '{"0":{"t":"麦当劳 午餐","m":"麦当劳","p":"麦当劳","c":"food","g":["外卖"],'
      '"n":"工作日午餐","d":"chill"}}',
      batch,
    );
    expect(copied['a']!.counterparty, isEmpty);
    expect(copied['a']!.merchant, '麦当劳');
    expect(copied['a']!.note, '工作日午餐');
    expect(copied['a']!.mood, ExpenseMood.chill);

    // 真的写了对方名字才保留
    final named = parseAiCaptureFields(
      '{"0":{"t":"转账给张三","m":"","p":"张三","c":"family","g":[],"n":"","d":"none"}}',
      batch,
    );
    expect(named['a']!.counterparty, '张三');

    // 心情写错就回到"无心情"
    final badMood = parseAiCaptureFields(
      '{"0":{"t":"x","m":"麦当劳","p":"","c":"food","g":[],"n":"","d":"很开心"}}',
      batch,
    );
    expect(badMood['a']!.mood, ExpenseMood.none);
  });
  test('merchant category cache skips the model for known merchants', () {
    AutoCaptureRecord capture(String id, String merchant) => AutoCaptureRecord(
      id: id,
      title: '微信付款 · $merchant',
      merchant: merchant,
      counterpartyName: '',
      rawBody: '微信支付 付款成功 30.00',
      scenario: 'merchantPayment',
      detailSummary: '商家：$merchant',
      amount: 30,
      entryType: EntryType.expense,
      channel: PaymentChannel.wechatPay,
      source: CaptureSource.wechat,
      capturedAt: DateTime(2026, 10, 6),
      postedAtMillis: DateTime(2026, 10, 6).millisecondsSinceEpoch,
      confidence: 0.9,
      defaultCategoryId: 'daily',
      profileId: 0,
      mergeKey: id,
      relatedSources: const [],
    );
    final cache = {'麦当劳': 'food'};

    // 老商户直接用缓存，不必再问模型
    final hits = applyMerchantCategoryCache(cache, [
      capture('a', '麦当劳'),
      capture('b', '新店'),
      capture('c', '未识别商户'),
    ]);
    expect(hits, {'a': 'food'});

    // 新商户问过之后写进缓存
    final updated = rememberMerchantCategories(cache, {
      'b': const AiCaptureFields(
        categoryId: 'daily',
        title: '',
        merchant: '',
        counterparty: '',
        tags: [],
      ),
    }, [capture('a', '麦当劳'), capture('b', '新店')]);
    expect(updated['麦当劳'], 'food');
    expect(updated['新店'], 'daily');
  });
  test('the app learns from a category correction', () {
    LedgerEntry entry(String id, String merchant, String categoryId,
            {bool auto = true}) =>
        LedgerEntry(
          id: id,
          title: '微信付款 · $merchant',
          merchant: merchant,
          note: '',
          amount: 30,
          type: EntryType.expense,
          categoryId: categoryId,
          channel: PaymentChannel.wechatPay,
          occurredAt: DateTime(2026, 10, 6),
          autoCaptured: auto,
          sourceLabel: '微信',
        );

    // 千问记成"购物"，用户改成"餐饮" → 记住这个商户
    final learned = learnMerchantCategory(
      const {},
      entry('a', '盒马', 'shopping'),
      entry('a', '盒马', 'food'),
    );
    expect(learned, {'盒马': 'food'});

    // 分类没变就不学
    expect(
      learnMerchantCategory(
        const {},
        entry('a', '盒马', 'food'),
        entry('a', '盒马', 'food'),
      ),
      isEmpty,
    );

    // 手动记的账不参与学习
    expect(
      learnMerchantCategory(
        const {},
        entry('a', '盒马', 'shopping', auto: false),
        entry('a', '盒马', 'food', auto: false),
      ),
      isEmpty,
    );
  });

  test('low category confidence is flagged for review', () {
    AutoCaptureRecord capture() => AutoCaptureRecord(
      id: 'a',
      title: '微信付款 · 某某',
      merchant: '某某',
      counterpartyName: '',
      rawBody: '微信支付 付款成功 30.00',
      scenario: 'merchantPayment',
      detailSummary: '商家：某某',
      amount: 30,
      entryType: EntryType.expense,
      channel: PaymentChannel.wechatPay,
      source: CaptureSource.wechat,
      capturedAt: DateTime(2026, 10, 6),
      postedAtMillis: DateTime(2026, 10, 6).millisecondsSinceEpoch,
      confidence: 0.9,
      defaultCategoryId: 'daily',
      profileId: 0,
      mergeKey: 'a',
      relatedSources: const [],
    );
    final unsure = parseAiCaptureFields(
      '{"0":{"t":"x","m":"某某","p":"","c":"daily","cc":0.4,"g":[],"n":"","d":"none"}}',
      [capture()],
    );
    expect(unsure['a']!.categoryConfidence, 0.4);

    // 没写 cc 时按 0.8 处理
    final missing = parseAiCaptureFields(
      '{"0":{"t":"x","m":"某某","p":"","c":"daily","g":[],"n":"","d":"none"}}',
      [capture()],
    );
    expect(missing['a']!.categoryConfidence, 0.8);
  });
  test('unparseable AI output is salvaged or marked for review, never dropped', () {
    AutoCaptureRecord capture(String id) => AutoCaptureRecord(
      id: id,
      title: '微信付款 · 某某',
      merchant: '某某',
      counterpartyName: '',
      rawBody: '微信支付 付款成功 30.00',
      scenario: 'merchantPayment',
      detailSummary: '商家：某某',
      amount: 30,
      entryType: EntryType.expense,
      channel: PaymentChannel.wechatPay,
      source: CaptureSource.wechat,
      capturedAt: DateTime(2026, 10, 6),
      postedAtMillis: DateTime(2026, 10, 6).millisecondsSinceEpoch,
      confidence: 0.9,
      defaultCategoryId: 'daily',
      profileId: 0,
      mergeKey: id,
      relatedSources: const [],
    );
    final batch = [capture('a'), capture('b')];

    // 正常 JSON：严格解析
    expect(
      parseAiCaptureFields('{"0":{"c":"food"},"1":{"c":"daily"}}', batch).length,
      2,
    );

    // JSON 被写坏/截断：从文本里抢救，且把握标低（会进待确认）
    final salvaged = salvageAiCaptureFields(
      '嗯，我看看：{"0":{"c":"food"}, "1": {"c": "dai',
      batch,
    );
    expect(salvaged['a']!.categoryId, 'food');
    expect(salvaged['a']!.categoryConfidence, lessThan(0.7));

    // 完全认不出来 → 交给调用方按「待确认」落账，而不是丢掉
    expect(salvageAiCaptureFields('我不知道', batch), isEmpty);
    expect(parseAiCaptureFields('我不知道', batch), isEmpty);
  });
  test('funding account is read from the notification, never invented', () {
    AutoCaptureRecord capture(String detail, String body) => AutoCaptureRecord(
      id: 'x',
      title: '银行通知',
      merchant: '',
      counterpartyName: '',
      rawBody: body,
      scenario: 'merchantPayment',
      detailSummary: detail,
      amount: 38,
      entryType: EntryType.expense,
      channel: PaymentChannel.bankCard,
      source: CaptureSource.bank,
      capturedAt: DateTime(2026, 10, 6, 19, 20, 8),
      postedAtMillis: DateTime(2026, 10, 6, 19, 20, 8).millisecondsSinceEpoch,
      confidence: 0.9,
      defaultCategoryId: 'daily',
      profileId: 0,
      mergeKey: 'x',
      relatedSources: const [],
    );

    // 三种常见写法都能认出来
    expect(
      extractFundingAccount(capture('招商银行尾号8821消费人民币38.00元', '')),
      '招商银行 ••8821',
    );
    expect(
      extractFundingAccount(capture('您尾号 1234 的储蓄卡消费38元', '')),
      contains('1234'),
    );
    // 认不出就不填，不能编一个卡号
    expect(extractFundingAccount(capture('支付成功 ¥38', '支付成功 ¥38')), isEmpty);
  });

  test('correlation score merges bank+payment but not two same-price buys', () {
    final base = DateTime(2026, 10, 6, 19, 20, 3);
    LedgerEntry entry({
      required double amount,
      required String sourceLabel,
      required DateTime at,
      String funding = '',
      String merchant = '',
    }) => LedgerEntry(
      id: 'e',
      title: '微信付款',
      merchant: merchant,
      note: '',
      amount: amount,
      type: EntryType.expense,
      categoryId: 'daily',
      channel: PaymentChannel.wechatPay,
      occurredAt: at,
      autoCaptured: true,
      sourceLabel: sourceLabel,
      autoProfileId: 0,
      autoPostedAtMillis: at.millisecondsSinceEpoch,
      fundingAccount: funding,
    );
    AutoCaptureRecord bank(double amount, DateTime at) => AutoCaptureRecord(
      id: 'b',
      title: '招商银行',
      merchant: '',
      counterpartyName: '',
      rawBody: '消费人民币¥{amount}元',
      scenario: 'merchantPayment',
      detailSummary: '招商银行尾号8821消费',
      amount: amount,
      entryType: EntryType.expense,
      channel: PaymentChannel.bankCard,
      source: CaptureSource.bank,
      capturedAt: at,
      postedAtMillis: at.millisecondsSinceEpoch,
      confidence: 0.95,
      defaultCategoryId: 'daily',
      profileId: 0,
      mergeKey: 'b',
      relatedSources: const [],
    );

    // 银行扣款 + 支付通知：金额一致、5 秒内、渠道互补、卡尾号一致 → 直接合并
    final strong = captureCorrelationScore(
      entry(amount: 38, sourceLabel: '微信', at: base, funding: '招商银行 ••8821'),
      bank(38, base.add(const Duration(seconds: 5))),
    );
    expect(strong, greaterThanOrEqualTo(captureAutoMergeThreshold));

    // 两笔都是 20 元、不同商户、隔了一分钟：分数不够，绝不能并成一笔
    final weak = captureCorrelationScore(
      entry(
        amount: 20,
        sourceLabel: '微信',
        at: base,
        merchant: '麦当劳',
      ),
      bank(20, base.add(const Duration(minutes: 1))),
    );
    expect(weak, lessThan(captureAutoMergeThreshold));
  });
  test('fuzzy search finds a transaction from a vague memory', () {
    LedgerEntry entry(
      String id,
      String title,
      String merchant,
      String note,
      String categoryId,
      DateTime at,
      double amount,
    ) => LedgerEntry(
      id: id,
      title: title,
      merchant: merchant,
      note: note,
      amount: amount,
      type: EntryType.expense,
      categoryId: categoryId,
      channel: PaymentChannel.wechatPay,
      occurredAt: at,
      autoCaptured: true,
      sourceLabel: '微信',
    );
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        entry('a', '淘宝 · 手机壳', '数码配件店', '淘宝 · XX数码配件店',
            'shopping', DateTime(2026, 10, 4), 39),
        entry('b', '麦当劳 午餐', '麦当劳', '工作日午餐', 'food',
            DateTime(2026, 10, 5), 35),
        entry('c', '滴滴出行', '滴滴', '打车去公司', 'mobility',
            DateTime(2026, 10, 3), 26),
      ],
    );
    final now = DateTime(2026, 10, 6);

    // "买手机配件那笔" → 应该先命中数码配件店，而不是麦当劳
    final hits = searchLedgerFuzzy(book, '前几天买手机配件那笔钱', now: now);
    expect(hits, isNotEmpty);
    expect(hits.first.entry.id, 'a');
    expect(hits.first.semantic, greaterThan(0));

    // 分类关键词也算语义线索：问"打车"能命中出行分类
    expect(searchLedgerFuzzy(book, '打车', now: now).first.entry.id, 'c');

    // 完全无关的问题不硬凑
    expect(searchLedgerFuzzy(book, '恐龙化石', now: now), isEmpty);

    // 给模型看的候选只有几行，不是整个账本
    final described = describeSearchHits(hits);
    expect(described.split('\n').length, lessThanOrEqualTo(5));
    expect(described, contains('39.00'));
  });
  test('notification templates are learned so the model is needed less over time', () {
    AutoCaptureRecord capture(String id, String body) => AutoCaptureRecord(
      id: id,
      title: '招商银行',
      merchant: '',
      counterpartyName: '',
      rawBody: body,
      scenario: 'merchantPayment',
      detailSummary: body,
      amount: 36.8,
      entryType: EntryType.expense,
      channel: PaymentChannel.bankCard,
      source: CaptureSource.bank,
      capturedAt: DateTime(2026, 10, 6, 19, 36),
      postedAtMillis: DateTime(2026, 10, 6, 19, 36).millisecondsSinceEpoch,
      confidence: 0.95,
      defaultCategoryId: 'daily',
      profileId: 0,
      mergeKey: id,
      relatedSources: const [],
    );
    const fields = AiCaptureFields(
      categoryId: 'daily',
      title: '',
      merchant: '',
      counterparty: '',
      tags: [],
    );

    // 两条只差数字的通知，骨架必须一样
    final a = capture('a', '您账户尾号8821于19:36消费人民币36.80元');
    final b = capture('b', '您账户尾号5572于20:12消费人民币120.00元');
    expect(captureTemplateSignature(a), captureTemplateSignature(b));

    // 命中够 3 次之前仍然问模型，够次数之后才算可信
    var templates = rememberCaptureTemplate(const {}, a, fields);
    expect(isCaptureTemplateTrusted(templates[captureTemplateSignature(a)]), isFalse);
    templates = rememberCaptureTemplate(templates, a, fields);
    expect(isCaptureTemplateTrusted(templates[captureTemplateSignature(a)]), isFalse);
    templates = rememberCaptureTemplate(templates, a, fields);
    expect(isCaptureTemplateTrusted(templates[captureTemplateSignature(a)]), isTrue);

    // 存进账本再读出来，模板还在
    final book = LedgerBook.empty(false).copyWith(
      captureTemplates: templates,
      capturePathStats: const {'template': 5, 'cache': 3, 'ai': 2},
    );
    final restored = LedgerBook.fromJson(book.toJson());
    expect(
      isCaptureTemplateTrusted(
        restored.captureTemplates[captureTemplateSignature(a)],
      ),
      isTrue,
    );
    expect(restored.capturePathStats['template'], 5);
    expect(restored.capturePathStats['ai'], 2);
  });
  test('learned delay widens the merge window for slow banks', () {
    // 学到的延迟：招商银行通知平均最晚 40 秒才来
    final profile = rememberCaptureDelay(const {}, CaptureSource.bank, 40000);
    expect(profile['bank'], 40000);
    // 窗口至少 90 秒；学到的延迟超过 90 秒才会放宽
    expect(captureWindowMs(const {}, CaptureSource.bank), 90000);
    expect(captureWindowMs(profile, CaptureSource.bank), 90000);
    final slower = rememberCaptureDelay(const {}, CaptureSource.bank, 150000);
    expect(captureWindowMs(slower, CaptureSource.bank), 150000);

    // 只记更大的一次，不会越来越小
    final again = rememberCaptureDelay(profile, CaptureSource.bank, 12000);
    expect(again['bank'], 40000);
  });

  test('notification order is learned and shown in plain words', () {
    var sequence = rememberCaptureSequence(const {}, CaptureSource.wechat, CaptureSource.bank);
    sequence = rememberCaptureSequence(sequence, CaptureSource.wechat, CaptureSource.bank);
    sequence = rememberCaptureSequence(sequence, CaptureSource.wechat, CaptureSource.wechat);
    expect(sequence['wechat>bank'], 2);
    expect(sequence.containsKey('wechat>wechat'), isFalse);
    expect(topCaptureSequenceLabel(sequence), contains('微信'));
    expect(topCaptureSequenceLabel(sequence), contains('已见 2 次'));
    // 只见过一次就不下结论
    expect(topCaptureSequenceLabel(const {'wechat>bank': 1}), isEmpty);
  });

  test('anomalies are found by statistics, not by guesswork', () {
    LedgerEntry entry(String id, String merchant, double amount, DateTime at) =>
        LedgerEntry(
          id: id,
          title: merchant,
          merchant: merchant,
          note: '',
          amount: amount,
          type: EntryType.expense,
          categoryId: 'food',
          channel: PaymentChannel.wechatPay,
          occurredAt: at,
          autoCaptured: true,
          sourceLabel: '微信',
        );
    final now = DateTime(2026, 10, 6, 20);
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        // 重复扣款：同商户同金额，相隔 2 分钟
        entry('a', '麦当劳', 36, now.subtract(const Duration(minutes: 12))),
        entry('b', '麦当劳', 36, now.subtract(const Duration(minutes: 10))),
        // 涨价：平时 15 元上下，这次 30 元
        entry('c', 'Spotify', 15, now.subtract(const Duration(days: 30))),
        entry('d', 'Spotify', 15, now.subtract(const Duration(days: 20))),
        entry('e', 'Spotify', 15, now.subtract(const Duration(days: 10))),
        entry('f', 'Spotify', 30, now.subtract(const Duration(days: 1))),
      ],
    );
    final anomalies = detectLedgerAnomalies(book, now: now);
    expect(anomalies.any((item) => item.kind == 'duplicate'), isTrue);
    final jump = anomalies.firstWhere((item) => item.kind == 'priceJump');
    expect(jump.detail, contains('中位数'));
    expect(jump.detail, contains('100%'));
    // 正常账本不报异常
    final calm = LedgerBook.empty(false).copyWith(
      entries: [entry('g', '瑞幸', 20, now.subtract(const Duration(days: 3)))],
    );
    expect(detectLedgerAnomalies(calm, now: now), isEmpty);
  });

  test('facts and inferences are kept apart', () {
    final entry = LedgerEntry(
      id: 'x',
      title: '麦当劳 午餐',
      merchant: '麦当劳',
      note: '',
      amount: 35,
      type: EntryType.expense,
      categoryId: 'food',
      channel: PaymentChannel.wechatPay,
      occurredAt: DateTime(2026, 10, 6),
      autoCaptured: true,
      sourceLabel: '微信',
      inferredFields: const {'categoryId', 'title' },
    );
    final restored = LedgerEntry.fromJson(entry.toJson());
    expect(restored.inferredFields, {'categoryId', 'title'});
    // 金额是通知里的事实，不在推测集合里
    expect(restored.inferredFields.contains('amount'), isFalse);
  });
  test('precomputed stats match a full scan and refresh when the book changes', () {
    LedgerEntry entry(String id, double amount, EntryType type, String categoryId,
            DateTime at) =>
        LedgerEntry(
          id: id,
          title: 'x',
          merchant: 'm',
          note: '',
          amount: amount,
          type: type,
          categoryId: categoryId,
          channel: PaymentChannel.wechatPay,
          occurredAt: at,
          autoCaptured: false,
          sourceLabel: '微信',
        );
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        entry('a', 30, EntryType.expense, 'food', DateTime(2026, 10, 6, 12)),
        entry('b', 12, EntryType.expense, 'food', DateTime(2026, 10, 6, 18)),
        entry('c', 100, EntryType.income, 'daily', DateTime(2026, 10, 6, 9)),
        entry('d', 50, EntryType.expense, 'shopping', DateTime(2026, 10, 5)),
      ],
    );
    final index = buildLedgerStatsIndex(book);
    final today = index.range(DateTime(2026, 10, 6), DateTime(2026, 10, 6));
    expect(today.expense, 42);
    expect(today.income, 100);
    expect(today.count, 3);
    expect(today.byCategory['food'], 42);
    final week = index.range(DateTime(2026, 10, 1), DateTime(2026, 10, 7));
    expect(week.expense, 92);
    expect(week.count, 4);

    // 查询引擎：同样的数字，走缓存和不走缓存必须一致
    final spec = LedgerQuerySpec(
      intent: 'sum',
      categoryId: 'food',
      startDate: DateTime(2026, 10, 6),
      endDate: DateTime(2026, 10, 6),
    );
    final cached = runLedgerQuery(book, spec, now: DateTime(2026, 10, 6), statsIndex: index);
    final scanned = runLedgerQuery(book, spec, now: DateTime(2026, 10, 6));
    expect(cached.text, contains('42.00'));
    expect(cached.text, scanned.text);

    // #14：加一笔账，重建后的统计立刻跟上（不会用到旧数字）
    final grown = book.copyWith(
      entries: [
        ...book.entries,
        entry('e', 8, EntryType.expense, 'food', DateTime(2026, 10, 6, 20)),
      ],
    );
    final rebuilt = buildLedgerStatsIndex(grown);
    expect(
      rebuilt.range(DateTime(2026, 10, 6), DateTime(2026, 10, 6)).expense,
      50,
    );
  });

  test('each field has its own confidence bar', () {
    // 分类 0.68 已经够了（>0.65），商户 0.70 还不够（<0.75）
    expect(
      fieldsNeedingReview(merchantConfidence: 0.70, categoryConfidence: 0.68),
      {'merchant'},
    );
    expect(
      fieldsNeedingReview(merchantConfidence: 0.90, categoryConfidence: 0.40),
      {'category'},
    );
    expect(
      fieldsNeedingReview(merchantConfidence: 0.90, categoryConfidence: 0.80),
      isEmpty,
    );
    // 金额的门槛最高：金额错了整本账都不可信
    expect(
      captureFieldThresholds['amount']!,
      greaterThan(captureFieldThresholds['category']!),
    );
  });
  test('common questions are understood locally, without asking the model', () {
    LedgerEntry entry(String id, String title, String merchant, double amount,
            String categoryId, DateTime at) =>
        LedgerEntry(
          id: id,
          title: title,
          merchant: merchant,
          note: '',
          amount: amount,
          type: EntryType.expense,
          categoryId: categoryId,
          channel: PaymentChannel.wechatPay,
          occurredAt: at,
          autoCaptured: true,
          sourceLabel: '微信',
        );
    final now = DateTime(2026, 10, 6, 20);
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        entry('a', '麦当劳 午餐', '麦当劳', 30, 'food', DateTime(2026, 10, 6, 12)),
        entry('b', '淘宝 · 手机壳', '数码配件店', 39, 'shopping', DateTime(2026, 10, 4)),
        entry('c', '微信付款 · 某某', '某某', 78, 'daily', DateTime(2026, 10, 2, 19)),
        entry('d', '瑞幸咖啡', '瑞幸', 22, 'food', DateTime(2026, 9, 20)),
      ],
    );

    // 「我最近有什么消费」→ 最近 30 天，列出流水
    final s1 = parseLedgerQuerySpecByRules('我最近有什么消费', now: now, book: book);
    expect(s1, isNotNull);
    expect(s1!.intent, 'find');
    expect(s1.startDate, DateTime(2026, 9, 7));
    expect(runLedgerQuery(book, s1, now: now).entryIds, isNotEmpty);

    // 「我有个78的消费记录吗」→ 按金额精确找
    final s2 = parseLedgerQuerySpecByRules('我有个78的消费记录吗', now: now, book: book);
    expect(s2, isNotNull);
    expect(s2!.intent, 'find');
    expect(s2.amount, 78);
    final found = runLedgerQuery(book, s2, now: now);
    expect(found.entryIds, ['c']);
    expect(found.text, contains('78.00'));

    // 「什么时间」→ 追问，继承上一轮的金额条件，答出日期
    final s3 = parseLedgerQuerySpecByRules('什么时间', now: now, book: book);
    expect(s3, isNotNull);
    expect(s3!.intent, 'latest');
    final merged = s3.mergedWith(s2);
    expect(merged.amount, 78);
    expect(runLedgerQuery(book, merged, now: now).text, contains('2026-10-02'));

    // 今天 / 分类 / 商户 也都认得
    final today = parseLedgerQuerySpecByRules('今天花了多少', now: now, book: book)!;
    expect(today.intent, 'sum');
    expect(today.startDate, DateTime(2026, 10, 6));
    final food = parseLedgerQuerySpecByRules('这个月餐饮花了多少', now: now, book: book)!;
    expect(food.categoryId, 'food');
    expect(food.intent, 'sum');
    final merchant = parseLedgerQuerySpecByRules('麦当劳花了多少', now: now, book: book)!;
    expect(merchant.merchant, '麦当劳');

    // 完全无关的话不求强解 —— 交给模型，模型不行就如实说没听懂
    expect(parseLedgerQuerySpecByRules('今天天气怎么样', now: now, book: book), isNull);
    expect(parseLedgerQuerySpecByRules('帮我看看这个', now: now, book: book), isNull);
  });
  test('transfers are their own type: not spending, not income', () {
    LedgerEntry entry(String id, double amount, EntryType type, DateTime at,
            {String categoryId = 'daily'}) =>
        LedgerEntry(
          id: id,
          title: id,
          merchant: '妈妈',
          note: '',
          amount: amount,
          type: type,
          categoryId: categoryId,
          channel: PaymentChannel.wechatPay,
          occurredAt: at,
          autoCaptured: true,
          sourceLabel: '微信',
        );
    final now = DateTime(2026, 10, 6, 20);
    final book = LedgerBook.empty(false).copyWith(
      entries: [
        entry('午餐', 100, EntryType.expense, DateTime(2026, 10, 6, 12)),
        entry('转账给妈妈', 200, EntryType.transfer, DateTime(2026, 10, 6, 13),
            categoryId: 'transfer'),
        entry('收到转账', 50, EntryType.transfer, DateTime(2026, 10, 6, 14),
            categoryId: 'transfer'),
      ],
    );

    // 「转账」是一个正式分类，属于 transfer 类型
    expect(
      categoriesForType(EntryType.transfer).map((c) => c.id),
      contains('transfer'),
    );
    expect(EntryType.transfer.label, '转账');

    // 求和：只算真正的消费，转账不进支出
    final sum = runLedgerQuery(
      book,
      LedgerQuerySpec(
        intent: 'sum',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 31),
      ),
      now: now,
    );
    expect(sum.text, contains('100.00'));
    expect(sum.text, isNot(contains('300.00')));
    expect(sum.text, contains('收入0.00元'));

    // 统计缓存：金额不算转账，但笔数照算
    final index = buildLedgerStatsIndex(book);
    final day = index.range(DateTime(2026, 10, 6), DateTime(2026, 10, 6));
    expect(day.expense, 100);
    expect(day.income, 0);
    expect(day.count, 3);

    // 异常提醒也不会把转账当成消费异常
    expect(detectLedgerAnomalies(book, now: now), isEmpty);
  });
}
