// ignore_for_file: library_private_types_in_public_api, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

part 'ui_extensions.dart';
part 'ui_predict_cards.dart';
part 'nlp_engine.dart';
part 'ui_voice_fab.dart';
part 'location_helper.dart';
part 'ui_location_map.dart';
part 'local_ai.dart';
part 'local_ai_download.dart';
part 'local_ai_pages.dart';
part 'local_ai_chat.dart';
part 'local_capture.dart';
part 'local_ledger_query.dart';
part 'local_ledger_search.dart';
part 'local_ledger_alerts.dart';
part 'local_ledger_stats.dart';

const _uuid = Uuid();
const _ledgerFileName = 'chaoxi_vault.enc';
const _legacyLedgerFileName = 'jier_vault.esa';
const _vaultCipherPrefix = 'cx2:';
const _encryptedBackupFormat = 'chaoxi.encrypted_backup.v2';
const _legacyEncryptedBackupFormats = {'jier.encrypted_backup.v1'};
const _unset = Object();

final _compactDateFormatter = DateFormat('yyyy-MM-dd');

/// 千问自己也没把握的分类会打这个标签；你改过一次之后就会记住这个商户。
const _needsReviewTag = '待确认';

/// 从通知里认出"资金来源账户"：银行/支付通知常写"尾号8821""信用卡1234""****8821"。
/// 认不出就返回空串 —— 宁可不填，也不编一个卡号出来。
String extractFundingAccount(AutoCaptureRecord capture) {
  final text = '${capture.detailSummary} ${capture.rawBody} ${capture.title}';
  final tail = RegExp(
    r'(?:尾号|卡号后四位|后四位|末四位|卡末四位)\s*[*＊]{0,4}\s*(\d{4})',
  ).firstMatch(text)?.group(1);
  final masked = tail ??
      RegExp(r'[*＊]{2,}\s*(\d{4})').firstMatch(text)?.group(1);
  if (masked == null || masked.isEmpty) return '';
  final bank = RegExp(r'([\u4e00-\u9fa5]{2,6}银行)').firstMatch(text)?.group(1);
  final label = (bank == null || bank.isEmpty)
      ? capture.source.label
      : bank;
  return '$label ••$masked';
}


/// #3 记录一次"第二条通知比第一条晚到多久"，学这个 App 的通知延迟。
Map<String, int> rememberCaptureDelay(
  Map<String, int> profile,
  CaptureSource source,
  int deltaMs,
) {
  if (deltaMs <= 0) return profile;
  final key = source.name;
  final capped = deltaMs.clamp(0, 5 * 60 * 1000);
  final existing = profile[key] ?? 0;
  if (capped <= existing) return profile;
  return {...profile, key: capped};
}

/// 学到的等待窗口：银行这类慢通知可以放宽，最少 90 秒。
int captureWindowMs(Map<String, int> profile, CaptureSource source) {
  final learned = profile[source.name] ?? 0;
  return math.max(90 * 1000, learned);
}

/// #4 记录通知顺序：微信付款之后通常还会来一条银行通知。
Map<String, int> rememberCaptureSequence(
  Map<String, int> sequence,
  CaptureSource from,
  CaptureSource to,
) {
  if (from == to || from == CaptureSource.unknown || to == CaptureSource.unknown) {
    return sequence;
  }
  final key = '${from.name}>${to.name}';
  return {...sequence, key: (sequence[key] ?? 0) + 1};
}

/// 给界面看的一句话：最常出现的通知顺序。
String topCaptureSequenceLabel(Map<String, int> sequence) {
  if (sequence.isEmpty) return '';
  final top = sequence.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final best = top.first;
  if (best.value < 2) return '';
  final parts = best.key.split('>');
  if (parts.length != 2) return '';
  final from = CaptureSource.values.firstWhere(
    (item) => item.name == parts[0],
    orElse: () => CaptureSource.unknown,
  );
  final to = CaptureSource.values.firstWhere(
    (item) => item.name == parts[1],
    orElse: () => CaptureSource.unknown,
  );
  if (from == CaptureSource.unknown || to == CaptureSource.unknown) return '';
  return '常见顺序：${from.label} → ${to.label}（已见 ${best.value} 次）';
}
/// 通知模板：把数字/时间挖掉，只留文字骨架。
/// "您账户尾号8821于19:36消费人民币36.80元" → "您账户尾号#于#消费人民币#元"
/// 同一个 App 的同类通知骨架一样，复用够多次之后就不必再问模型。
String captureTemplateSignature(AutoCaptureRecord capture) {
  final text = '${capture.title} ${capture.rawBody} ${capture.detailSummary}'
      .replaceAll(RegExp(r'\d+(?:[.:]\d+)*'), '#')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final skeleton = text.length > 60 ? text.substring(0, 60) : text;
  return '${capture.source.name}|$skeleton';
}

/// 一个已经学会的通知模板。
class CaptureTemplate {
  const CaptureTemplate({
    required this.categoryId,
    this.hits = 1,
    this.misses = 0,
  });

  /// 模型第一次判断出来的分类。
  final String categoryId;

  /// 这个骨架被成功复用了几次。
  final int hits;

  /// 用户改过几次（改过就说明模板不可信，要重新学）。
  final int misses;

  Map<String, dynamic> toJson() => {
    'categoryId': categoryId,
    'hits': hits,
    'misses': misses,
  };

  factory CaptureTemplate.fromJson(Map<String, dynamic> json) =>
      CaptureTemplate(
        categoryId: json['categoryId'] as String? ?? '',
        hits: (json['hits'] as num?)?.toInt() ?? 1,
        misses: (json['misses'] as num?)?.toInt() ?? 0,
      );
}

/// 模板要连续命中几次才算"可信"（防止一条特殊通知就把模板学歪）。
const captureTemplateTrustThreshold = 3;

/// 记录一次模板复用。
Map<String, CaptureTemplate> rememberCaptureTemplate(
  Map<String, CaptureTemplate> templates,
  AutoCaptureRecord capture,
  AiCaptureFields fields,
) {
  if (fields.categoryId.isEmpty) return templates;
  final signature = captureTemplateSignature(capture);
  final existing = templates[signature];
  return {
    ...templates,
    signature: CaptureTemplate(
      categoryId: fields.categoryId,
      hits: (existing?.hits ?? 0) + 1,
      misses: existing?.misses ?? 0,
    ),
  };
}


/// 模板是否已经可信（命中够多、且没被用户改过）。
bool isCaptureTemplateTrusted(CaptureTemplate? template) =>
    template != null &&
    template.misses == 0 &&
    template.hits >= captureTemplateTrustThreshold;

/// 关联打分：判断两条通知是不是同一笔交易（0~100）。
/// ≥90 程序直接合并；60~89 需要 AI 复核；<60 不作为候选。
/// 金额相同只是其中一个条件 —— 单看金额会把"麦当劳20元"和"罗森20元"错并成一笔。
int captureCorrelationScore(LedgerEntry entry, AutoCaptureRecord capture) {
  if (entry.autoProfileId != capture.profileId) return 0;
  if (entry.type != capture.entryType) return 0;
  var score = 0;
  final sameAmount =
      entry.amount > 0 &&
      capture.amount > 0 &&
      (entry.amount - capture.amount).abs() < 0.01;
  if (sameAmount) score += 40;

  final delta = (_entryEventMillis(entry) - capture.postedAtMillis).abs();
  if (delta <= const Duration(seconds: 10).inMilliseconds) {
    score += 25;
  } else if (delta <= const Duration(seconds: 30).inMilliseconds) {
    score += 20;
  } else if (delta <= const Duration(minutes: 2).inMilliseconds) {
    score += 10;
  }

  final existingSource = CaptureSource.fromLabelOrUnknown(entry.sourceLabel);
  final incoming = capture.source;
  if (existingSource != CaptureSource.unknown && existingSource != incoming) {
    final existingIsChannel = existingSource.isPaymentSource;
    final incomingIsChannel = incoming.isPaymentSource;
    final existingIsPlatform = existingSource.isShoppingSource;
    final incomingIsPlatform = incoming.isShoppingSource;
    if ((existingIsChannel && incomingIsPlatform) ||
        (existingIsPlatform && incomingIsChannel)) {
      score += 20;
    } else if ((existingIsChannel && incoming == CaptureSource.bank) ||
        (existingSource == CaptureSource.bank && incomingIsChannel)) {
      score += 20;
    } else if ((existingIsPlatform && incoming == CaptureSource.bank) ||
        (existingSource == CaptureSource.bank && incomingIsPlatform)) {
      score += 15;
    }
  }

  // 同一张卡/同一个尾号，是很强的证据
  final incomingAccount = extractFundingAccount(capture);
  if (entry.fundingAccount.isNotEmpty &&
      incomingAccount.isNotEmpty &&
      entry.fundingAccount == incomingAccount) {
    score += 25;
  }

  // 通知里明确写了"付款成功""消费"这类词
  final paidKeywords = ['付款成功', '支付成功', '消费', '扣款', '支出'];
  final incomingText = '${capture.title} ${capture.detailSummary} ${capture.rawBody}';
  if (paidKeywords.any(incomingText.contains)) score += 10;

  return score.clamp(0, 100);
}

/// 两个"银行 + 支付"的强关联候选同时存在时不要自动合并：宁可分成两笔让你核对，
/// 也不要把两笔真实消费并成一笔。
const captureAutoMergeThreshold = 90;

final _safeCurrencyFormatter = NumberFormat.currency(
  locale: 'zh_CN',
  symbol: '\u00A5',
);
final _safeMonthFormatter = DateFormat("M'\u6708'");
final _safeFullDateFormatter = DateFormat("M'\u6708'd'\u65e5' EEEE", 'zh_CN');

Future<T?> pushPremiumPage<T>(BuildContext context, {required Widget page}) {
  return Navigator.of(
    context,
  ).push<T>(_PremiumPageRoute<T>(builder: (_) => page));
}

class _PremiumPageRoute<T> extends PageRouteBuilder<T> {
  _PremiumPageRoute({required WidgetBuilder builder})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) =>
            RepaintBoundary(child: builder(context)),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final slide = Tween<Offset>(
            begin: const Offset(0.045, 0),
            end: Offset.zero,
          ).animate(curve);
          final opacity = Tween<double>(begin: 0, end: 1).animate(curve);

          return FadeTransition(
            opacity: opacity,
            child: SlideTransition(position: slide, child: child),
          );
        },
      );
}

final vaultRepositoryProvider = Provider<LedgerVaultRepository>((ref) {
  return LedgerVaultRepository(const VaultCryptoBridge());
});

final autoCaptureBridgeProvider = Provider<AndroidAutoCaptureBridge>((ref) {
  return const AndroidAutoCaptureBridge();
});

final windowPrivacyBridgeProvider = Provider<AndroidWindowPrivacyBridge>((ref) {
  return const AndroidWindowPrivacyBridge();
});

final biometricVaultBridgeProvider = Provider<BiometricVaultBridge>((ref) {
  return BiometricVaultBridge();
});

final ledgerControllerProvider =
    StateNotifierProvider<LedgerController, LedgerViewState>((ref) {
      return LedgerController(
        ref.read(vaultRepositoryProvider),
        ref.read(autoCaptureBridgeProvider),
        ref.read(windowPrivacyBridgeProvider),
        ref.read(biometricVaultBridgeProvider),
      );
    });

class JierApp extends StatelessWidget {
  const JierApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseColorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1867D8),
      brightness: Brightness.light,
      surface: const Color(0xFFF9FAFF),
    );

    final bodyTheme = GoogleFonts.plusJakartaSansTextTheme();
    final displayTheme = GoogleFonts.spaceGroteskTextTheme(bodyTheme);

    return MaterialApp(
      title: '潮汐账本',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: baseColorScheme,
        scaffoldBackgroundColor: const Color(0xFFF3F7FB),
        textTheme: displayTheme.copyWith(
          bodyLarge: bodyTheme.bodyLarge,
          bodyMedium: bodyTheme.bodyMedium,
          bodySmall: bodyTheme.bodySmall,
          labelLarge: bodyTheme.labelLarge,
          titleMedium: bodyTheme.titleMedium,
          titleSmall: bodyTheme.titleSmall,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          color: Colors.white.withValues(alpha: 0.9),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: const Color(0xFFF1F4FA),
          hintStyle: GoogleFonts.plusJakartaSans(
            color: const Color(0xFF73809A),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 16,
          ),
        ),
      ),
      home: const LedgerRootPage(),
    );
  }
}

class LedgerRootPage extends ConsumerStatefulWidget {
  const LedgerRootPage({super.key});

  @override
  ConsumerState<LedgerRootPage> createState() => _LedgerRootPageState();
}

class _LedgerRootPageState extends ConsumerState<LedgerRootPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Timer? _syncTimer;
  /// 切换标签时的一次性入场动画（淡入 + 轻微上浮），只跑 240 毫秒。
  late final AnimationController _tabTransition;
  late final Animation<double> _tabFade;
  late final Animation<Offset> _tabSlide;
  Timer? _noticeTimer;
  Timer? _errorTimer;
  int _selectedIndex = 0;

  // 五个页面在 IndexedStack 里都会参与构建。把它们的实例缓存下来，
  // 顶部提示、错误提示这类变化就不会把五个页面全部重建一遍。
  List<Widget>? _cachedScreens;
  String? _cachedScreensKey;
  LedgerBook? _cachedScreensBook;

  List<Widget> _screensFor(LedgerViewState state, LedgerBook book) {
    final key = [
      state.initializing,
      state.onboardingRequired,
      state.locked,
      state.biometricAvailable,
      state.notificationAccessGranted,
      state.revealAmounts,
      state.busy,
      state.lastAutoSyncAt?.millisecondsSinceEpoch ?? 0,
    ].join('|');
    final cached = _cachedScreens;
    if (cached != null &&
        _cachedScreensKey == key &&
        identical(_cachedScreensBook, book)) {
      return cached;
    }
    final screens = <Widget>[
      DashboardScreen(book: book, viewState: state),
      TransactionsScreen(book: book, viewState: state),
      PlansScreen(book: book, viewState: state),
      InsightsScreen(book: book, viewState: state),
      VaultScreen(book: book, viewState: state),
    ];
    _cachedScreens = screens;
    _cachedScreensKey = key;
    _cachedScreensBook = book;
    return screens;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabTransition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1,
    );
    final tabCurve = CurvedAnimation(
      parent: _tabTransition,
      curve: Curves.easeOutCubic,
    );
    _tabFade = Tween<double>(begin: 0.72, end: 1).animate(tabCurve);
    _tabSlide = Tween<Offset>(
      begin: const Offset(0, 0.018),
      end: Offset.zero,
    ).animate(tabCurve);
    _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      ref
          .read(ledgerControllerProvider.notifier)
          .syncAutoCapturedEntries(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _noticeTimer?.cancel();
    _errorTimer?.cancel();
    _tabTransition.dispose();
    super.dispose();
  }

  void _switchTab(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
    // 一次性入场动画：不循环，所以不会一直占用 CPU。
    _tabTransition.forward(from: 0);
  }

  void _scheduleTransientDismissals(
    LedgerViewState? previous,
    LedgerViewState next,
  ) {
    if (next.noticeMessage != null &&
        next.noticeMessage != previous?.noticeMessage) {
      _noticeTimer?.cancel();
      final notice = next.noticeMessage!;
      _noticeTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        ref.read(ledgerControllerProvider.notifier).clearNoticeMessage(notice);
      });
    }
    if (next.errorMessage != null &&
        next.errorMessage != previous?.errorMessage) {
      _errorTimer?.cancel();
      final error = next.errorMessage!;
      _errorTimer = Timer(const Duration(seconds: 7), () {
        if (!mounted) return;
        ref.read(ledgerControllerProvider.notifier).clearErrorMessage(error);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(ledgerControllerProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      controller.refreshNotificationPermission();
      controller.refreshBiometricAvailability();
      controller.syncAutoCapturedEntries(silent: true);
    }
    if (state == AppLifecycleState.paused) {
      controller.lockIfQuickLockEnabled();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<LedgerViewState>(ledgerControllerProvider, (previous, next) {
      if (previous?.locked == true && next.canShowShell) {
        FocusManager.instance.primaryFocus?.unfocus();
        if (_selectedIndex != 0 && mounted) {
          _switchTab(0);
        }
      }
      _scheduleTransientDismissals(previous, next);
    });
    final state = ref.watch(ledgerControllerProvider);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF5FAFF), Color(0xFFF4F9F6), Color(0xFFFFFBF6)],
          ),
        ),
        child: Stack(
          children: [
            const _AmbientBackground(),
            SafeArea(child: _buildStateBody(context, state)),
            if (_selectedIndex == 0 &&
                state.book != null &&
                state.book!.settings.voiceInputEnabled)
              VoiceRecordingFab(
                book: state.book!,
                controller: ref.read(ledgerControllerProvider.notifier),
              ),
          ],
        ),
      ),
      bottomNavigationBar: state.canShowShell
          ? _BottomDockBar(
              selectedIndex: _selectedIndex,
              onSelected: (index) {
                if (_selectedIndex == index) return;
                HapticFeedback.selectionClick();
                _switchTab(index);
              },
            )
          : null,
    );
  }

  Widget _buildStateBody(BuildContext context, LedgerViewState state) {
    if (state.initializing) {
      return const _BootScreen();
    }

    if (state.onboardingRequired) {
      return const _VaultSetupScreen();
    }

    if (state.locked || state.book == null) {
      return const _VaultUnlockScreen();
    }

    final book = state.book!;
    final screens = _screensFor(state, book);

    final banners = <Widget>[
      if (state.noticeMessage case final notice?)
        _TopBanner(
          key: ValueKey('notice-$notice'),
          label: notice,
          icon: Icons.check_circle_outline,
          color: const Color(0xFF0B8457),
        ),
      if (state.errorMessage case final error?)
        _TopBanner(
          key: ValueKey('error-$error'),
          label: error,
          icon: Icons.error_outline,
          color: const Color(0xFFC44536),
        ),
    ];

    return Column(
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            reverseDuration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final slide = Tween<Offset>(
                begin: const Offset(0, -0.08),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: slide, child: child),
              );
            },
            child: banners.isEmpty
                ? const SizedBox(key: ValueKey('banner-empty'))
                : Column(
                    key: ValueKey(
                      'banner-stack-${state.noticeMessage}-${state.errorMessage}',
                    ),
                    children: banners,
                  ),
          ),
        ),
        Expanded(
          child: FadeTransition(
            opacity: _tabFade,
            child: SlideTransition(
              position: _tabSlide,
              child: IndexedStack(
                index: _selectedIndex.clamp(0, screens.length - 1),
                children: [
                  for (var i = 0; i < screens.length; i++)
                    TickerMode(
                      enabled: _selectedIndex == i,
                      child: KeyedSubtree(key: ValueKey(i), child: screens[i]),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class LedgerController extends StateNotifier<LedgerViewState> {
  LedgerController(
    this._repository,
    this._autoCaptureBridge,
    this._windowPrivacyBridge,
    this._biometricVaultBridge,
  ) : super(LedgerViewState.initial()) {
    initialize();
  }

  final LedgerVaultRepository _repository;
  final AndroidAutoCaptureBridge _autoCaptureBridge;
  final AndroidWindowPrivacyBridge _windowPrivacyBridge;
  final BiometricVaultBridge _biometricVaultBridge;
  String? _sessionPassphrase;
  bool _syncingAutoCapture = false;

  /// #15 后台常驻：队列里还有货时，用前台服务把进程留住，
  /// 定时把队列消化掉；队列清空就停掉服务，不白耗电。
  Timer? _drainTimer;
  bool _drainServiceRunning = false;

  void _updateDrainService({required int pending}) {
    if (pending <= 0) {
      _drainTimer?.cancel();
      _drainTimer = null;
      if (_drainServiceRunning) {
        _drainServiceRunning = false;
        unawaited(_autoCaptureBridge.stopDrainService());
      }
      return;
    }
    if (!_drainServiceRunning) {
      _drainServiceRunning = true;
      unawaited(_autoCaptureBridge.startDrainService(pending));
    }
    _drainTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      // 只在没锁屏、没在同步的时候跑，避免重复劳动。
      if (state.locked || _syncingAutoCapture) return;
      unawaited(syncAutoCapturedEntries(silent: true));
    });
  }

  @override
  void dispose() {
    _drainTimer?.cancel();
    super.dispose();
  }

  Future<void> initialize() async {
    state = state.copyWith(initializing: true, errorMessage: null);
    try {
      final vaultExists = await _repository.vaultExists();
      final notificationAccess = await _autoCaptureBridge
          .isNotificationAccessEnabled();
      final biometricAvailable = await _biometricVaultBridge
          .isBiometricAvailable();
      final allowScreenshots = await _windowPrivacyBridge
          .isScreenCaptureAllowed();
      await _applyScreenCapturePreference(allowScreenshots);
      state = state.copyWith(
        initializing: false,
        onboardingRequired: !vaultExists,
        locked: vaultExists,
        notificationAccessGranted: notificationAccess,
        biometricAvailable: biometricAvailable,
        canUseShell: false,
      );
    } catch (error) {
      state = state.copyWith(initializing: false, errorMessage: '初始化失败：$error');
    }
  }

  Future<void> createVault({
    required String passphrase,
    required bool confidentialModeEnabled,
  }) async {
    if (passphrase.trim().length < 6) {
      state = state.copyWith(errorMessage: '机密口令至少 6 位。');
      return;
    }

    final emptyBook = LedgerBook.empty(confidentialModeEnabled);
    if (!await _persistNewBook(emptyBook, passphrase)) return;
    state = state.copyWith(
      onboardingRequired: false,
      locked: false,
      canUseShell: true,
      noticeMessage: '保险库已经创建，当前是空白账本，只保留真实记账。',
      errorMessage: null,
    );
    await _syncBiometricPassphrase(emptyBook.settings, passphrase.trim());
    await syncAutoCapturedEntries(silent: true);
  }

  Future<void> unlockVault(
    String passphrase, {
    bool triggeredByBiometric = false,
  }) async {
    state = state.copyWith(busy: true, errorMessage: null, noticeMessage: null);
    try {
      final loadedBook = await _repository.load(passphrase.trim());
      final book = loadedBook
          .withoutLegacySeedData()
          .migrateAutoCapturedUtcTimes()
          .backfillAutoCaptureCounterpartyNames()
          .normalizeShoppingAutoCaptureTitles();
      _sessionPassphrase = passphrase.trim();
      if (!identical(book, loadedBook)) {
        await _repository.save(book, passphrase.trim());
      }
      state = state.copyWith(
        busy: false,
        locked: false,
        book: book,
        canUseShell: true,
        revealAmounts: !book.settings.maskAmounts,
        noticeMessage: identical(book, loadedBook)
            ? '保险库已解锁。'
            : '保险库已解锁，并已整理旧账本数据，只保留真实记账展示。',
      );
      await _applyScreenCapturePreference(
        book.settings.allowScreenshots,
        persist: true,
      );
      await _syncBiometricPassphrase(book.settings, passphrase.trim());
      await syncAutoCapturedEntries(silent: true);
    } catch (_) {
      _sessionPassphrase = null;
      state = state.copyWith(busy: false, errorMessage: '口令不正确，或保险库数据无法解密。');
      if (triggeredByBiometric) {
        await _biometricVaultBridge.clearPassphrase();
      }
    }
  }

  Future<void> lockVault({bool silent = false}) async {
    _sessionPassphrase = null;
    state = state.copyWith(
      locked: true,
      canUseShell: false,
      book: null,
      revealAmounts: false,
      noticeMessage: silent ? null : '保险库已上锁。',
    );
  }

  Future<void> lockIfQuickLockEnabled() async {
    final book = state.book;
    if (book != null && book.settings.quickLockOnBackground) {
      await lockVault(silent: true);
    }
  }

  Future<void> resetVault() async {
    try {
      await _repository.deleteVault();
      _sessionPassphrase = null;
      state = state.copyWith(
        onboardingRequired: true,
        locked: false,
        book: null,
        canUseShell: false,
        revealAmounts: false,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(errorMessage: '重置失败：$e');
    }
  }

  void clearNoticeMessage(String expected) {
    if (state.noticeMessage != expected) {
      return;
    }
    state = state.copyWith(noticeMessage: null);
  }

  void clearErrorMessage(String expected) {
    if (state.errorMessage != expected) {
      return;
    }
    state = state.copyWith(errorMessage: null);
  }

  Future<void> refreshNotificationPermission() async {
    final access = await _autoCaptureBridge.isNotificationAccessEnabled();
    state = state.copyWith(notificationAccessGranted: access);
  }

  Future<void> refreshBiometricAvailability() async {
    final available = await _biometricVaultBridge.isBiometricAvailable();
    state = state.copyWith(biometricAvailable: available);
  }

  Future<void> openNotificationAccessSettings() async {
    await _autoCaptureBridge.openNotificationAccessSettings();
    await refreshNotificationPermission();
  }

  Future<void> revealAmounts(bool reveal) async {
    state = state.copyWith(revealAmounts: reveal);
  }

  Future<void> updateSettings(VaultSettings settings) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final updated = book.copyWith(
      settings: settings,
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '机密设置已更新。');
    if (identical(state.book, updated)) {
      await _syncBiometricPassphrase(settings, passphrase);
    }
  }

  Future<void> updateBook(LedgerBook book) async {
    final passphrase = _sessionPassphrase;
    if (passphrase == null) return;
    final updated = book.copyWith(updatedAt: DateTime.now());
    await _persistBook(updated, passphrase, notice: '账本规则已更新。');
  }

  /// #13/#14 统计缓存：账本一变（updatedAt / 条数不同）就重建，
  /// 天然不会和账本不一致；没变就直接复用。
  LedgerStatsIndex? _statsIndex;
  String _statsIndexKey = '';

  LedgerStatsIndex statsIndexFor(LedgerBook book) {
    final key = '${book.entries.length}|${book.updatedAt.millisecondsSinceEpoch}';
    if (_statsIndex == null || _statsIndexKey != key) {
      _statsIndex = buildLedgerStatsIndex(book);
      _statsIndexKey = key;
    }
    return _statsIndex!;
  }

  /// 上一轮问账本的查询条件，用来支持"那交通呢""上个月呢"这类追问。
  LedgerQuerySpec? _lastQuerySpec;
  LedgerQuerySpec? get lastQuerySpec => _lastQuerySpec;

  void rememberQuerySpec(LedgerQuerySpec? spec) {
    _lastQuerySpec = spec;
  }

  Future<bool> saveAiConversation(
    List<LedgerAiMessage> messages,
    List<String> focusEntryIds,
  ) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return false;
    final updated = book.copyWith(
      aiMessages: messages.skip(math.max(0, messages.length - 40)).toList(),
      aiFocusEntryIds: focusEntryIds.take(80).toList(),
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase);
    return identical(state.book, updated);
  }

  Future<void> updateBiometricUnlockEnabled(bool enabled) async {
    final book = state.book;
    if (book == null) return;
    if (enabled) {
      final available = await _biometricVaultBridge.isBiometricAvailable();
      state = state.copyWith(biometricAvailable: available);
      if (!available) {
        state = state.copyWith(errorMessage: '当前设备没有可用的指纹或生物识别，无法开启指纹解锁。');
        return;
      }
    }
    await updateSettings(
      book.settings.copyWith(biometricUnlockEnabled: enabled),
    );
  }

  Future<void> unlockWithBiometric() async {
    state = state.copyWith(busy: true, errorMessage: null, noticeMessage: null);
    try {
      final available = await _biometricVaultBridge.isBiometricAvailable();
      if (!available) {
        state = state.copyWith(busy: false, errorMessage: '当前设备未开启可用的指纹或生物识别。');
        return;
      }
      final passphrase = await _biometricVaultBridge.readPassphrase();
      if (passphrase == null || passphrase.trim().isEmpty) {
        state = state.copyWith(
          busy: false,
          errorMessage: '请先手动输入口令解锁一次，再在机密页开启指纹解锁。',
        );
        return;
      }
      final authenticated = await _biometricVaultBridge.authenticate();
      if (!authenticated) {
        state = state.copyWith(busy: false, noticeMessage: '本次指纹解锁已取消。');
        return;
      }
      await unlockVault(passphrase, triggeredByBiometric: true);
    } catch (error) {
      state = state.copyWith(busy: false, errorMessage: '指纹解锁失败：$error');
    }
  }

  Future<void> addEntry(LedgerEntry entry) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    // Save entry immediately — never block on location
    final updated = book.copyWith(
      entries: [...book.entries, entry]
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)),
      updatedAt: DateTime.now(),
    );
    await _persistBook(
      updated,
      passphrase,
      notice: '已添加一笔${entry.type.label}。',
    );

    // Backfill location in background (non-blocking)
    if (entry.locationInfo.isEmpty &&
        book.settings.locationMode != LocationTrackingMode.off) {
      _backfillLocation(entry.id);
    }
  }

  /// Fetches location asynchronously and patches the entry without blocking UI.
  Future<void> _backfillLocation(String entryId) async {
    try {
      final mode = state.book?.settings.locationMode;
      final locResult = mode == LocationTrackingMode.ipRough
          ? await LocationHelper.getApproximateLocation()
          : await LocationHelper.getDetailedLocation(
              forceRefresh: mode == LocationTrackingMode.backgroundPrecise,
            );
      if (locResult.isEmpty) return;

      final currentBook = state.book;
      final passphrase = _sessionPassphrase;
      if (currentBook == null || passphrase == null) return;

      final idx = currentBook.entries.indexWhere((e) => e.id == entryId);
      if (idx == -1) return;

      final patched = currentBook.entries[idx].copyWith(
        locationInfo: locResult.address,
        latitude: locResult.latitude,
        longitude: locResult.longitude,
      );

      final newEntries = [...currentBook.entries];
      newEntries[idx] = patched;

      final updatedBook = currentBook.copyWith(
        entries: newEntries,
        updatedAt: DateTime.now(),
      );
      await _persistBook(updatedBook, passphrase);
    } catch (_) {
      // Location backfill is best-effort; silently ignore failures
    }
  }

  Future<void> updateEntry(LedgerEntry entry) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final index = book.entries.indexWhere((item) => item.id == entry.id);
    if (index == -1) return;
    final previous = book.entries[index];

    // 手动改过分类，说明这条已经核对过，把「待确认」标签摘掉。
    final resolvedEntry = previous.categoryId == entry.categoryId
        ? entry
        : entry.copyWith(
            tags: entry.tags
                .where((tag) => tag != _needsReviewTag)
                .toList(),
          );

    final updatedEntries = [...book.entries];
    updatedEntries[index] = resolvedEntry;
    updatedEntries.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    // 学会用户的修改：自动记账的分类被你改过，就记住这个商户以后该记哪一类，
    // 下次同一个商户直接用，不用再问千问。
    final learned = learnMerchantCategory(
      book.merchantCategories,
      previous,
      entry,
    );
    final learnedMerchant = learned.length != book.merchantCategories.length
        ? entry.merchant.trim()
        : '';

    final updated = book.copyWith(
      entries: updatedEntries,
      merchantCategories: learned,
      updatedAt: DateTime.now(),
    );
    await _persistBook(
      updated,
      passphrase,
      notice: learnedMerchant.isEmpty
          ? '流水已更新。'
          : '流水已更新，并记住「$learnedMerchant」以后记'
                '${categoryForId(entry.categoryId).name}。',
    );
  }

  Future<void> deleteEntry(String entryId) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final remainingEntries = book.entries
        .where((entry) => entry.id != entryId)
        .toList();
    if (remainingEntries.length == book.entries.length) {
      return;
    }

    final updated = book.copyWith(
      entries: remainingEntries,
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '已删除一笔流水。');
  }

  Future<void> addBudget(
    BudgetEnvelope budget, {
    String? previousCategoryId,
  }) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final budgets = [
      ...book.budgets.where(
        (item) =>
            item.id != budget.id &&
            item.categoryId != budget.categoryId &&
            item.categoryId != previousCategoryId,
      ),
      budget,
    ];
    final updated = book.copyWith(budgets: budgets, updatedAt: DateTime.now());
    await _persistBook(updated, passphrase, notice: '预算计划已更新。');
  }

  Future<void> addGoal(SavingsGoal goal) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final updated = book.copyWith(
      goals: [...book.goals.where((item) => item.id != goal.id), goal],
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '生活目标已保存。');
  }

  Future<void> deleteGoal(String goalId) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final goals = book.goals.where((item) => item.id != goalId).toList();
    if (goals.length == book.goals.length) return;

    final updated = book.copyWith(goals: goals, updatedAt: DateTime.now());
    await _persistBook(updated, passphrase, notice: '生活目标已删除。');
  }

  Future<void> addSubscription(RecurringPlan plan) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final updated = book.copyWith(
      subscriptions: [
        ...book.subscriptions.where((item) => item.id != plan.id),
        plan,
      ],
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '订阅计划已保存。');
  }

  Future<void> deleteBudget(String budgetId) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final budgets = book.budgets.where((item) => item.id != budgetId).toList();
    if (budgets.length == book.budgets.length) return;

    final updated = book.copyWith(budgets: budgets, updatedAt: DateTime.now());
    await _persistBook(updated, passphrase, notice: '预算计划已删除。');
  }

  Future<void> deleteSubscription(String planId) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final subscriptions = book.subscriptions
        .where((item) => item.id != planId)
        .toList();
    if (subscriptions.length == book.subscriptions.length) return;

    final updated = book.copyWith(
      subscriptions: subscriptions,
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '固定支出计划已删除。');
  }

  Future<String?> upsertPeriod(LedgerPeriod period) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return '账本暂不可用。';
    if (!period.endAt.isAfter(period.startAt)) {
      return '结束时间必须晚于开始时间。';
    }

    final overlap = book.periods.firstWhereOrNull(
      (item) =>
          item.id != period.id &&
          _ledgerPeriodsOverlap(
            item.startAt,
            item.endAt,
            period.startAt,
            period.endAt,
          ),
    );
    if (overlap != null) {
      return '账期不能重叠，当前和“${overlap.name}”有时间交叉。';
    }

    final updatedPeriods = [
      ...book.periods.where((item) => item.id != period.id),
      period,
    ]..sort((a, b) => a.startAt.compareTo(b.startAt));
    final updated = book.copyWith(
      periods: updatedPeriods,
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '命名账期已保存。');
    return null;
  }

  Future<void> deletePeriod(String periodId) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final periods = book.periods.where((item) => item.id != periodId).toList();
    if (periods.length == book.periods.length) return;

    final updated = book.copyWith(periods: periods, updatedAt: DateTime.now());
    await _persistBook(updated, passphrase, notice: '命名账期已删除。');
  }

  Future<void> addFavoriteLocation(FavoriteLocation location) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final updated = book.copyWith(
      favoriteLocations: [...book.favoriteLocations, location],
      updatedAt: DateTime.now(),
    );
    await _persistBook(
      updated,
      passphrase,
      notice: '已添加常用地点「${location.name}」。',
    );
  }

  Future<void> removeFavoriteLocation(String id) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final locations = book.favoriteLocations
        .where((item) => item.id != id)
        .toList();
    if (locations.length == book.favoriteLocations.length) return;

    final updated = book.copyWith(
      favoriteLocations: locations,
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '常用地点已删除。');
  }

  Future<void> updateFavoriteLocation(FavoriteLocation location) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final locations = book.favoriteLocations.map((item) {
      return item.id == location.id ? location : item;
    }).toList();
    final updated = book.copyWith(
      favoriteLocations: locations,
      updatedAt: DateTime.now(),
    );
    await _persistBook(updated, passphrase, notice: '常用地点已更新。');
  }

  Future<void> syncAutoCapturedEntries({bool silent = false}) async {
    if (_syncingAutoCapture) return;
    _syncingAutoCapture = true;
    try {
      await _syncAutoCapturedEntries(silent: silent);
    } finally {
      _syncingAutoCapture = false;
    }
  }

  Future<void> _syncAutoCapturedEntries({required bool silent}) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null ||
        passphrase == null ||
        !book.settings.autoCaptureEnabled) {
      return;
    }

    final access = await _autoCaptureBridge.isNotificationAccessEnabled();
    // 只有真的变了才更新状态。原来每 20 秒都写一次，会让整个界面无谓重建。
    if (state.notificationAccessGranted != access) {
      state = state.copyWith(notificationAccessGranted: access);
    }
    if (!access) {
      if (!silent) {
        state = state.copyWith(errorMessage: '尚未授予通知读取权限，无法自动记账。');
      }
      return;
    }

    // 一轮只处理一小批：AI 顺序处理时新通知继续进队列，
    // 监听和处理互不阻塞，剩下的下一轮（20 秒后）继续。
    const batchSize = 12;
    final pending = await _autoCaptureBridge.fetchPendingRecords();
    final captures = pending.length > batchSize
        ? pending.take(batchSize).toList()
        : pending;
    if (captures.isEmpty) {
      if (!silent) {
        state = state.copyWith(
          noticeMessage: '没有新的自动记账记录。',
          lastAutoSyncAt: DateTime.now(),
        );
      }
      return;
    }

    final allowedCaptures =
        captures
            .where(
              (capture) => _isCaptureEnabled(book.settings, capture.source),
            )
            .toList()
          ..sort((a, b) => a.postedAtMillis.compareTo(b.postedAtMillis));

    if (allowedCaptures.isEmpty) {
      _updateDrainService(pending: 0);
      await _autoCaptureBridge.acknowledgeRecords(captures);
      state = state.copyWith(
        lastAutoSyncAt: DateTime.now(),
        noticeMessage: silent ? state.noticeMessage : '发现新通知，但已被当前自动导入策略忽略。',
      );
      return;
    }

    // 记账用小模型：装了多个模型时，自动用最小的那个跑通知解析。
    final aiModel = await _captureModelFor(book.settings);
    // 通知的字段和分类全部由千问生成：没跑上模型的记录**留在队列里**等下一轮，
    // 绝不先用规则拼一条半成品记进账本。
    // 先看缓存：同一个商户千问只判断一次，之后直接复用它的结论。
    final cachedCategories = applyMerchantCategoryCache(
      book.merchantCategories,
      allowedCaptures,
    );
    // 模板快路径：同一个 App 的同类通知见过够多次之后，直接复用结论，不问模型。
    // 顺序很重要：商户缓存优先于模板 —— 你手动改过的分类要压过模板。
    final templateHits = <String, String>{};
    for (final capture in allowedCaptures) {
      if (cachedCategories.containsKey(capture.id)) continue;
      final template = book.captureTemplates[captureTemplateSignature(capture)];
      if (isCaptureTemplateTrusted(template)) {
        templateHits[capture.id] = template!.categoryId;
      }
    }
    final needAi = allowedCaptures
        .where(
          (capture) =>
              !cachedCategories.containsKey(capture.id) &&
              !templateHits.containsKey(capture.id),
        )
        .toList();
    final aiBatch = needAi.isEmpty
        ? const LocalAiCaptureBatch.empty()
        : await classifyCapturesWithAi(
            needAi,
            aiModel,
            spec: book.settings.aiCaptureSpec,
            // 用户自己配的分类规则直接交给千问遵守，规则仍然由用户说了算。
            rules: book.customRules,
          );
    // 模型没跑上：整批留在队列里等下一轮（不是丢弃）。
    if (aiBatch == null) return;
    final aiFields = aiBatch.fields;
    final fields = <String, AiCaptureFields>{
      for (final entry in cachedCategories.entries)
        entry.key: AiCaptureFields(
          categoryId: entry.value,
          title: '',
          merchant: '',
          counterparty: '',
          tags: const [],
        ),
      for (final entry in templateHits.entries)
        entry.key: AiCaptureFields(
          categoryId: entry.value,
          title: '',
          merchant: '',
          counterparty: '',
          tags: const [],
        ),
      ...aiFields,
    };
    // 千问跑过但怎么都解析不出来的：按「待确认」落账，不能因为一次失败就把通知丢掉。
    final needsReview = aiBatch.unresolved;
    final readyCaptures = allowedCaptures
        .where(
          (capture) =>
              fields.containsKey(capture.id) ||
              needsReview.contains(capture.id),
        )
        .toList();
    // 跑不上的留着，其它（含被策略忽略的）才算处理完。
    final waiting = allowedCaptures.length - readyCaptures.length;
    final ackList = captures
        .where(
          (capture) =>
              !allowedCaptures.contains(capture) ||
              fields.containsKey(capture.id),
        )
        .toList();
    if (readyCaptures.isEmpty) {
      _updateDrainService(pending: waiting);
      state = state.copyWith(
        lastAutoSyncAt: DateTime.now(),
        noticeMessage: silent
            ? state.noticeMessage
            : '千问暂时没跑起来，$waiting 条通知先留在队列里，装好模型后会自动记账。',
      );
      return;
    }

    final workingEntries = [...book.entries];
    var createdCount = 0;
    var updatedCount = 0;
    final createdEntryIds = <String>{};
    // 边用边学：这次合并的延迟和来源顺序都记下来。
    var delayProfile = book.captureDelayProfile;
    var sequence = book.captureSequence;

    for (final capture in readyCaptures) {
      // 千问这次没给出可用字段的，落账时标「待确认」，等你扫一眼。
      final captureNeedsReview = needsReview.contains(capture.id);
      final sameIdIndex = workingEntries.indexWhere(
        (entry) => entry.id == capture.id,
      );
      if (sameIdIndex != -1) {
        final before = workingEntries[sameIdIndex];
        delayProfile = rememberCaptureDelay(
          delayProfile,
          capture.source,
          (capture.postedAtMillis - _entryEventMillis(before)).abs(),
        );
        sequence = rememberCaptureSequence(
          sequence,
          CaptureSource.fromLabelOrUnknown(before.sourceLabel),
          capture.source,
        );
        workingEntries[sameIdIndex] = await _mergeEntryWithCapture(
          workingEntries[sameIdIndex],
          capture,
          book,
          aiFields: fields[capture.id],
          needsReview: captureNeedsReview,
        );
        updatedCount++;
        continue;
      }

      final mergeIndex = _findMergeTargetIndex(
        workingEntries,
        capture,
        book.captureDelayProfile,
      );
      if (mergeIndex != -1) {
        final before = workingEntries[mergeIndex];
        delayProfile = rememberCaptureDelay(
          delayProfile,
          capture.source,
          (capture.postedAtMillis - _entryEventMillis(before)).abs(),
        );
        sequence = rememberCaptureSequence(
          sequence,
          CaptureSource.fromLabelOrUnknown(before.sourceLabel),
          capture.source,
        );
        workingEntries[mergeIndex] = await _mergeEntryWithCapture(
          workingEntries[mergeIndex],
          capture,
          book,
          aiFields: fields[capture.id],
          needsReview: captureNeedsReview,
        );
        updatedCount++;
        continue;
      }

      final candidate = await _captureToEntry(
        capture,
        book,
        aiFields: fields[capture.id],
        needsReview: captureNeedsReview,
      );
      if (_containsSimilarAutoEntry(workingEntries, candidate)) {
        continue;
      }
      workingEntries.add(candidate);
      createdCount++;
      createdEntryIds.add(candidate.id);
    }

    if (createdCount == 0 && updatedCount == 0) {
      await _autoCaptureBridge.acknowledgeRecords(ackList);
      state = state.copyWith(
        lastAutoSyncAt: DateTime.now(),
        noticeMessage: silent ? state.noticeMessage : '自动记账通知已读取，无需新增或合并更新。',
      );
      return;
    }

    _linkRefundBindings(workingEntries);
    // 把这次千问的判断沉淀成模板：同类通知下次直接命中，不再问模型。
    var templates = book.captureTemplates;
    for (final capture in needAi) {
      final captureFields = aiFields[capture.id];
      if (captureFields != null) {
        templates = rememberCaptureTemplate(templates, capture, captureFields);
      }
    }
    // 统计这次走了哪条路，用来验证"越用越少依赖 AI"。
    final pathStats = {...book.capturePathStats};
    void bump(String key, int count) {
      if (count > 0) pathStats[key] = (pathStats[key] ?? 0) + count;
    }
    bump('template', templateHits.length);
    bump('cache', cachedCategories.length);
    bump('ai', aiFields.length);
    final updatedBook = book.copyWith(
      entries: [...workingEntries]
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)),
      // 记住这次千问判断过的商户，下次同一个商户不用再问模型。
      merchantCategories: rememberMerchantCategories(
        book.merchantCategories,
        aiFields,
        needAi,
      ),
      captureTemplates: templates,
      capturePathStats: pathStats,
      captureDelayProfile: delayProfile,
      captureSequence: sequence,
      updatedAt: DateTime.now(),
    );
    final backlog = pending.length - captures.length;
    // 队列里还有货 → 让前台服务把进程留住继续消化；空了就停掉。
    _updateDrainService(pending: backlog + waiting);
    final reviewCount = readyCaptures
        .where((capture) => needsReview.contains(capture.id))
        .length;
    final summary = <String>[
      if (createdCount > 0) '$createdCount 笔新增',
      if (updatedCount > 0) '$updatedCount 笔合并更新',
      if (reviewCount > 0) '$reviewCount 条已记为待确认',
      if (waiting > 0) '还有 $waiting 条等千问处理',
      if (backlog > 0) '另有 $backlog 条排队中',
    ].join('，');
    if (_sessionPassphrase != passphrase ||
        state.locked ||
        !identical(state.book, book)) {
      return;
    }
    await _persistBook(
      updatedBook,
      passphrase,
      notice: '自动记账已同步 $summary，覆盖微信 / 支付宝 / Google Pay / 淘宝 / 京东 / 拼多多 / 闲鱼。',
      lastAutoSyncAt: DateTime.now(),
    );
    if (identical(state.book, updatedBook)) {
      await _autoCaptureBridge.acknowledgeRecords(ackList);
    }

    // Backfill location for newly created entries (if enabled)
    if (identical(state.book, updatedBook) &&
        book.settings.autoRecordLocation &&
        book.settings.locationMode != LocationTrackingMode.off &&
        createdCount > 0) {
      for (final entry in workingEntries.where(
        (entry) => createdEntryIds.contains(entry.id),
      )) {
        if (DateTime.now().difference(entry.occurredAt).inMinutes.abs() <= 5) {
          unawaited(_backfillLocation(entry.id));
        }
      }
    }
  }

  /// 账本的字段由千问生成（标题/商户/对象/分类/标签）；
  /// 金额和收支方向始终来自通知解析，模型碰不到这两项。
  Future<LedgerEntry> _captureToEntry(
    AutoCaptureRecord capture,
    LedgerBook book, {
    AiCaptureFields? aiFields,
    bool needsReview = false,
  }) async {
    final categoryId = aiFields?.categoryId ??
        (capture.entryType == EntryType.expense
            ? resolveDefaultExpenseCategoryId(book.settings)
            : _fallbackCategoryIdForType(EntryType.income));
    final displaySource = capture.source.isShoppingSource
        ? capture.source
        : capture.relatedSources.firstWhereOrNull(
                (item) => item.isShoppingSource,
              ) ??
              capture.source;

    final scenarioLabel = switch (capture.scenario) {
      'codePayment' => '收款码付款',
      'codeReceipt' => '收款码收款',
      'transferPayment' => '转账支出',
      'transferReceipt' => '转账收入',
      'merchantPayment' => '商家付款',
      'merchantReceipt' => '商家收款',
      'walletPayment' => '钱包付款',
      'walletReceipt' => '钱包收款',
      'refund' => '退款',
      'platformPayment' => '平台支付',
      'platformRefund' => '平台退款',
      'receipt' => '收款',
      _ => '付款',
    };

    final sourceTags = {
      capture.source.label,
      ...capture.relatedSources.map((item) => item.label),
      if (capture.entryType == EntryType.expense &&
          capture.source != CaptureSource.unknown)
        '${capture.source.label}消费',
      if (capture.entryType == EntryType.income &&
          capture.source != CaptureSource.unknown)
        '${capture.source.label}入账',
    }.toList();

    // 标题、商户、对象优先用千问按用户规范生成的结果。
    final aiMerchant = aiFields?.merchant ?? '';
    final aiCounterparty = aiFields?.counterparty ?? '';
    final resolvedMerchant = aiMerchant.isNotEmpty
        ? aiMerchant
        : capture.merchant;
    final resolvedCounterparty = aiCounterparty.isNotEmpty
        ? aiCounterparty
        : capture.counterpartyName;
    final aiTitle = aiFields?.title ?? '';
    return LedgerEntry(
      id: capture.id,
      title: aiTitle.isNotEmpty
          ? aiTitle
          : buildAutoCaptureDisplayTitle(
              source: displaySource,
              scenario: capture.scenario,
              merchant: resolvedMerchant,
              counterpartyName: resolvedCounterparty,
            ),
      merchant: resolvedMerchant,
      counterpartyName: resolvedCounterparty,
      // 备注和心情也是「新增支出」表单里的字段，由千问一起生成；
      // 千问没给备注时保留通知原文，方便日后搜索。
      note: (aiFields?.note.isNotEmpty ?? false)
          ? aiFields!.note
          : _normalizedAutoCaptureNote(
              detailSummary: capture.detailSummary,
              rawBody: capture.rawBody,
              counterpartyName: resolvedCounterparty,
              entryType: capture.entryType,
            ),
      mood: aiFields?.mood ?? ExpenseMood.none,
      // 记录哪些字段是千问推测的（不是通知里的事实）。
      inferredFields: (aiFields == null)
          ? const <String>{}
          : {
              if (aiTitle.isNotEmpty) 'title',
              if (aiMerchant.isNotEmpty) 'merchant',
              if (aiCounterparty.isNotEmpty) 'counterpartyName',
              'categoryId',
              if (aiFields.tags.isNotEmpty) 'tags',
              if (aiFields.note.isNotEmpty) 'note',
              if (aiFields.mood != ExpenseMood.none) 'mood',
            },
      amount: capture.amount,
      type: capture.entryType,
      categoryId: categoryId,
      channel: capture.channel,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(capture.postedAtMillis),
      // 资金来源账户：商户、支付渠道、账户是三件事，分开存。
      fundingAccount: extractFundingAccount(capture),
      tags: [
        ...sourceTags,
        scenarioLabel,
        ...?aiFields?.tags,
        if (aiFields != null) '千问整理',
        // 千问自己也没把握：标出来让你扫一眼，改一次它就记住了。
        if (needsReview ||
            (aiFields != null && aiFields.categoryConfidence < 0.7))
          _needsReviewTag,
      ],
      locationInfo: '',
      autoCaptured: true,
      sourceLabel: capture.source.label,
      autoMergeKey: capture.mergeKey,
      autoProfileId: capture.profileId,
      autoPostedAtMillis: capture.postedAtMillis,
    );
  }

  bool _isCaptureEnabled(VaultSettings settings, CaptureSource source) {
    return switch (source) {
      CaptureSource.wechat => settings.wechatEnabled,
      CaptureSource.alipay => settings.alipayEnabled,
      CaptureSource.googlePay => settings.googlePayEnabled,
      CaptureSource.taobao => settings.taobaoEnabled,
      CaptureSource.jd => settings.jdEnabled,
      CaptureSource.pinduoduo => settings.pinduoduoEnabled,
      CaptureSource.xianyu => settings.xianyuEnabled,
      CaptureSource.bank => settings.bankEnabled,
      CaptureSource.unknown => false,
    };
  }


  int _findMergeTargetIndex(
    List<LedgerEntry> entries,
    AutoCaptureRecord capture,
    Map<String, int> delayProfile,
  ) {
    // --- Strategy 1: Exact match (same amount, tight window) ---
    final exactMatch = entries.lastIndexWhere((entry) {
      if (!entry.autoCaptured) return false;
      if (entry.autoProfileId != capture.profileId) return false;
      if (entry.type != capture.entryType) return false;
      if ((entry.amount - capture.amount).abs() > 0.009) return false;
      final delta = (_entryEventMillis(entry) - capture.postedAtMillis).abs();
      if (delta > const Duration(minutes: 10).inMilliseconds) return false;

      // mergeKey match
      if (entry.autoMergeKey.isNotEmpty && capture.mergeKey.isNotEmpty) {
        if (entry.autoMergeKey == capture.mergeKey ||
            entry.autoMergeKey.contains(capture.mergeKey) ||
            capture.mergeKey.contains(entry.autoMergeKey)) {
          return true;
        }
      }

      // counterparty name match
      if (entry.counterpartyName.isNotEmpty &&
          capture.counterpartyName.isNotEmpty &&
          (entry.counterpartyName == capture.counterpartyName ||
              entry.counterpartyName.contains(capture.counterpartyName) ||
              capture.counterpartyName.contains(entry.counterpartyName))) {
        return true;
      }

      // Cross-source match (e.g. taobao notification + wechat payment)
      final existingSource = CaptureSource.fromLabelOrUnknown(
        entry.sourceLabel,
      );
      return existingSource != CaptureSource.unknown &&
          existingSource != capture.source &&
          (existingSource.isPaymentSource != capture.source.isPaymentSource);
    });
    if (exactMatch != -1) return exactMatch;

    // --- Strategy 1.5: 关联打分 ---
    // 银行扣款 + 支付通知这类组合（金额一致、卡尾号一致）用打分判断，
    // ≥90 直接合并；存在多个同样强的候选时宁可不合并，避免把两笔真实消费并成一笔。
    final strongCandidates = <int>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (!entry.autoCaptured) continue;
      if (captureCorrelationScore(entry, capture) >= captureAutoMergeThreshold) {
        strongCandidates.add(i);
      }
    }
    if (strongCandidates.length == 1) return strongCandidates.first;

    // --- Strategy 2: Cross-source enrichment (shopping → payment or vice versa) ---
    // When you buy on Taobao, you first get a Taobao notification (with store name),
    // then a WeChat/Alipay payment notification (with amount). These should merge.
    // We use a wider time window (30 mins) and allow amount mismatch when one side
    // is a shopping source and the other is a payment source.
    final isCaptureFromPayment = capture.source.isPaymentSource;
    final isCaptureFromShopping = capture.source.isShoppingSource;

    if (isCaptureFromPayment || isCaptureFromShopping) {
      final crossMatch = entries.lastIndexWhere((entry) {
        if (!entry.autoCaptured) return false;
        if (entry.autoProfileId != capture.profileId) return false;
        if (entry.type != capture.entryType) return false;

        final existingSource = CaptureSource.fromLabelOrUnknown(
          entry.sourceLabel,
        );
        if (existingSource == CaptureSource.unknown) return false;
        if (existingSource == capture.source) return false;

        // Must be a shopping↔payment pair
        final isValidPair =
            (isCaptureFromPayment && existingSource.isShoppingSource) ||
            (isCaptureFromShopping && existingSource.isPaymentSource);
        if (!isValidPair) return false;

        // 跨来源的时间窗：一开始按 90 秒，学到某个 App 通知来得慢（比如银行）
        // 就自动放宽到它实际的最大延迟，免得晚到的通知并不到一起。
        final delta = (_entryEventMillis(entry) - capture.postedAtMillis).abs();
        if (delta > captureWindowMs(delayProfile, capture.source)) return false;

        // Amount match (if both have amounts, they should be close)
        if (capture.amount > 0 && entry.amount > 0) {
          if ((entry.amount - capture.amount).abs() > 0.5) return false;
        }

        // mergeKey / merchant fuzzy match
        if (entry.autoMergeKey.isNotEmpty && capture.mergeKey.isNotEmpty) {
          if (entry.autoMergeKey == capture.mergeKey ||
              entry.autoMergeKey.contains(capture.mergeKey) ||
              capture.mergeKey.contains(entry.autoMergeKey)) {
            return true;
          }
        }

        // Merchant name fuzzy match
        if (entry.merchant.isNotEmpty && capture.merchant.isNotEmpty) {
          final eMerchant = entry.merchant.toLowerCase();
          final cMerchant = capture.merchant.toLowerCase();
          if (eMerchant == cMerchant ||
              eMerchant.contains(cMerchant) ||
              cMerchant.contains(eMerchant)) {
            return true;
          }
        }

        // If amounts match exactly and it's a valid cross-source pair,
        // that's enough evidence to merge
        if (capture.amount > 0 &&
            entry.amount > 0 &&
            (entry.amount - capture.amount).abs() < 0.01) {
          return true;
        }

        return false;
      });
      if (crossMatch != -1) return crossMatch;
    }

    return -1;
  }

  Future<LedgerEntry> _mergeEntryWithCapture(
    LedgerEntry existing,
    AutoCaptureRecord capture,
    LedgerBook book, {
    AiCaptureFields? aiFields,
    bool needsReview = false,
  }) async {
    final candidate = await _captureToEntry(
      capture,
      book,
      aiFields: aiFields,
      needsReview: needsReview,
    );
    final existingSource = CaptureSource.fromLabelOrUnknown(
      existing.sourceLabel,
    );
    final promoteCapture =
        capture.source.isPaymentSource && !existingSource.isPaymentSource;
    final mergedSourceLabel = promoteCapture || existing.sourceLabel.isEmpty
        ? candidate.sourceLabel
        : existing.sourceLabel;
    final mergedChannel =
        promoteCapture || existing.channel == PaymentChannel.other
        ? candidate.channel
        : existing.channel;
    // Smart merchant picking: shopping sources (Taobao/JD/PDD) typically have
    // the real store name, while payment sources (WeChat/Alipay) often just say
    // "未识别商户". Always prefer the shopping source's richer merchant info.
    final incomingIsRicher =
        capture.source.isShoppingSource && existingSource.isPaymentSource;
    final existingIsRicher =
        existingSource.isShoppingSource && capture.source.isPaymentSource;
    final String mergedMerchant;
    if (incomingIsRicher &&
        candidate.merchant.isNotEmpty &&
        candidate.merchant != '未识别商户') {
      mergedMerchant = candidate.merchant;
    } else if (existingIsRicher &&
        existing.merchant.isNotEmpty &&
        existing.merchant != '未识别商户') {
      mergedMerchant = existing.merchant;
    } else {
      mergedMerchant = _pickPreferredText(
        existing: existing.merchant,
        incoming: candidate.merchant,
        preferIncoming: promoteCapture,
      );
    }
    final mergedCounterpartyName = _pickPreferredText(
      existing: existing.counterpartyName,
      incoming: candidate.counterpartyName,
      preferIncoming: promoteCapture,
    );
    // 分类以千问这次给出的结果为准；没有新结果就保留原记录的分类。
    final mergedCategoryId =
        aiFields?.categoryId ??
        (existing.categoryId.isNotEmpty
            ? existing.categoryId
            : candidate.categoryId);
    final lockedFields = existing.manualOverrideFields.toSet();
    final mergedOccurredAt = existing.occurredAt.isBefore(candidate.occurredAt)
        ? existing.occurredAt
        : candidate.occurredAt;
    final mergedAutoPostedAtMillis = [
      if (existing.autoPostedAtMillis > 0) existing.autoPostedAtMillis,
      capture.postedAtMillis,
    ].reduce(math.min);

    return LedgerEntry(
      id: existing.id,
      title: lockedFields.contains('title')
          ? existing.title
          : _pickMergedEntryTitle(
              existing: existing,
              incoming: candidate,
              existingSource: existingSource,
              incomingSource: capture.source,
              preferIncoming: promoteCapture,
            ),
      merchant: lockedFields.contains('merchant')
          ? existing.merchant
          : mergedMerchant,
      counterpartyName: lockedFields.contains('counterpartyName')
          ? existing.counterpartyName
          : mergedCounterpartyName,
      note: lockedFields.contains('note')
          ? existing.note
          : _normalizedAutoCaptureNote(
              detailSummary: _mergeLines(existing.note, candidate.note),
              rawBody: candidate.note,
              counterpartyName: mergedCounterpartyName,
              entryType: lockedFields.contains('type')
                  ? existing.type
                  : candidate.type,
            ),
      // #7 冲突解析：金额以"更权威的来源"为准 —— 银行通知 > 支付渠道 > 电商平台。
      // 三条通知都写了金额时，不能谁后到就用谁。
      amount: lockedFields.contains('amount')
          ? existing.amount
          : (existingSource == CaptureSource.bank &&
                    capture.source != CaptureSource.bank
                ? existing.amount
                : candidate.amount),
      type: lockedFields.contains('type') ? existing.type : candidate.type,
      categoryId: lockedFields.contains('categoryId')
          ? existing.categoryId
          : mergedCategoryId,
      channel: lockedFields.contains('channel')
          ? existing.channel
          : mergedChannel,
      occurredAt: lockedFields.contains('occurredAt')
          ? existing.occurredAt
          : mergedOccurredAt,
      tags: lockedFields.contains('tags')
          ? existing.tags
          : {
              ...existing.tags,
              ...candidate.tags,
              if (existingSource != CaptureSource.unknown &&
                  existingSource != capture.source &&
                  promoteCapture)
                existingSource.label,
            }.toList(),
      autoCaptured: true,
      sourceLabel: mergedSourceLabel,
      // 三条通知并成一条账时，谁先带来资金来源账户就留下它。
      fundingAccount: existing.fundingAccount.isNotEmpty
          ? existing.fundingAccount
          : candidate.fundingAccount,
      autoMergeKey: capture.mergeKey.isNotEmpty
          ? capture.mergeKey
          : existing.autoMergeKey,
      autoProfileId: capture.profileId != -1
          ? capture.profileId
          : existing.autoProfileId,
      autoPostedAtMillis: mergedAutoPostedAtMillis,
      manualOverrideFields: existing.manualOverrideFields,
    );
  }

  String _pickMergedEntryTitle({
    required LedgerEntry existing,
    required LedgerEntry incoming,
    required CaptureSource existingSource,
    required CaptureSource incomingSource,
    required bool preferIncoming,
  }) {
    if (existingSource.isShoppingSource && incomingSource.isPaymentSource) {
      return existing.title;
    }
    if (incomingSource.isShoppingSource && existingSource.isPaymentSource) {
      return incoming.title;
    }
    return preferIncoming
        ? incoming.title
        : _pickPreferredText(
            existing: existing.title,
            incoming: incoming.title,
            preferIncoming: false,
          );
  }

  String _pickPreferredText({
    required String existing,
    required String incoming,
    required bool preferIncoming,
  }) {
    if (incoming.isEmpty || incoming == '未识别对象' || incoming == '未识别商户') {
      return existing;
    }
    if (existing.isEmpty || existing == '未识别对象' || existing == '未识别商户') {
      return incoming;
    }
    if (preferIncoming) return incoming;
    return incoming.length > existing.length ? incoming : existing;
  }

  String _mergeLines(String left, String right) {
    return <String>{
      ...left
          .split('\\n')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
      ...right
          .split('\\n')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
    }.join('\\n');
  }

  bool _containsSimilarAutoEntry(
    List<LedgerEntry> entries,
    LedgerEntry candidate,
  ) {
    return entries.any((entry) {
      final timeDelta =
          (_entryEventMillis(entry) - _entryEventMillis(candidate)).abs();
      return entry.autoCaptured &&
          (entry.id == candidate.id ||
              (entry.autoProfileId == candidate.autoProfileId &&
                  entry.autoMergeKey.isNotEmpty &&
                  entry.autoMergeKey == candidate.autoMergeKey &&
                  entry.amount == candidate.amount &&
                  timeDelta < const Duration(minutes: 10).inMilliseconds) ||
              (entry.amount == candidate.amount &&
                  (entry.counterpartyName == candidate.counterpartyName ||
                      entry.merchant == candidate.merchant) &&
                  entry.sourceLabel == candidate.sourceLabel &&
                  timeDelta < const Duration(minutes: 3).inMilliseconds));
    });
  }

  Future<bool> _persistNewBook(LedgerBook book, String passphrase) async {
    await _persistBook(book, passphrase.trim(), notice: '保险库已创建。');
    if (!identical(state.book, book)) return false;
    _sessionPassphrase = passphrase.trim();
    return true;
  }

  Future<void> _persistBook(
    LedgerBook book,
    String passphrase, {
    String? notice,
    DateTime? lastAutoSyncAt,
  }) async {
    state = state.copyWith(busy: true, errorMessage: null);
    try {
      await _repository.save(book, passphrase);
      await _applyScreenCapturePreference(
        book.settings.allowScreenshots,
        persist: true,
      );
      state = state.copyWith(
        busy: false,
        locked: false,
        canUseShell: true,
        book: book,
        revealAmounts: !book.settings.maskAmounts || state.revealAmounts,
        noticeMessage: notice,
        lastAutoSyncAt: lastAutoSyncAt ?? state.lastAutoSyncAt,
      );
    } catch (error) {
      state = state.copyWith(busy: false, errorMessage: '保存失败：$error');
    }
  }

  Future<void> _applyScreenCapturePreference(
    bool allowed, {
    bool persist = false,
  }) async {
    try {
      await _windowPrivacyBridge.setScreenCaptureAllowed(
        allowed,
        persist: persist,
      );
    } catch (_) {
      // Best effort only so privacy UI issues never block ledger access.
    }
  }

  Future<void> _syncBiometricPassphrase(
    VaultSettings settings,
    String passphrase,
  ) async {
    try {
      if (settings.biometricUnlockEnabled &&
          await _biometricVaultBridge.isBiometricAvailable()) {
        await _biometricVaultBridge.savePassphrase(passphrase);
      } else {
        await _biometricVaultBridge.clearPassphrase();
      }
    } catch (_) {
      // Best effort only so unlock settings never block normal ledger access.
    }
  }

  Future<void> importBackupFromJsonFile(String filePath) async {
    final currentBook = state.book;
    final passphrase = _sessionPassphrase;
    if (currentBook == null || passphrase == null) return;

    state = state.copyWith(busy: true, errorMessage: null, noticeMessage: null);
    try {
      final content = await File(filePath).readAsString();
      final decoded = jsonDecode(content);
      final payload = decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
      final bookPayload = payload['book'] is Map
          ? Map<String, dynamic>.from(payload['book'] as Map)
          : payload;
      final importedBook = LedgerBook.fromJson(bookPayload)
          .withoutLegacySeedData()
          .migrateAutoCapturedUtcTimes()
          .backfillAutoCaptureCounterpartyNames()
          .normalizeShoppingAutoCaptureTitles()
          .copyWith(updatedAt: DateTime.now());
      await _persistBook(
        importedBook,
        passphrase,
        notice: '本地 JSON 备份已导入，当前内容已替换为导入版本。',
      );
      if (identical(state.book, importedBook)) {
        await _syncBiometricPassphrase(importedBook.settings, passphrase);
      }
    } catch (error) {
      state = state.copyWith(
        busy: false,
        errorMessage: '导入失败：请确认是潮汐账本导出的 JSON 备份。错误：$error',
      );
    }
  }

  void _linkRefundBindings(List<LedgerEntry> entries) {
    final linkedRefundIds = <String>{};
    for (final e in entries) linkedRefundIds.addAll(e.linkedRefundEntryIds);
    final refundEntries = entries
        .where(
          (e) =>
              e.type == EntryType.income &&
              (e.tags.contains('退款') ||
                  e.tags.contains('平台退款') ||
                  e.sourceLabel.contains('退款') ||
                  e.title.contains('退款') ||
                  e.categoryId == 'refund'),
        )
        .toList();
    for (final refund in refundEntries) {
      if (linkedRefundIds.contains(refund.id)) continue;
      final candidateIndex = entries.indexWhere((expense) {
        if (expense.type != EntryType.expense) return false;
        if ((expense.amount - refund.amount).abs() > 0.009) return false;
        if (expense.occurredAt.isAfter(refund.occurredAt)) return false;
        if (refund.occurredAt.difference(expense.occurredAt).inDays > 90)
          return false;
        if (expense.merchant.isNotEmpty && expense.merchant == refund.merchant)
          return !expense.linkedRefundEntryIds.contains(refund.id);
        if (expense.counterpartyName.isNotEmpty &&
            expense.counterpartyName == refund.counterpartyName)
          return !expense.linkedRefundEntryIds.contains(refund.id);
        if (expense.sourceLabel == refund.sourceLabel)
          return !expense.linkedRefundEntryIds.contains(refund.id);
        return false;
      });
      if (candidateIndex != -1) {
        final target = entries[candidateIndex];
        entries[candidateIndex] = target.copyWith(
          linkedRefundEntryIds: [...target.linkedRefundEntryIds, refund.id],
        );
        linkedRefundIds.add(refund.id);
      }
    }
  }

  Future<void> importEncryptedBackupFromFile(
    String filePath,
    String backupPassword,
  ) async {
    final currentBook = state.book;
    final passphrase = _sessionPassphrase;
    if (currentBook == null || passphrase == null) return;

    state = state.copyWith(busy: true, errorMessage: null, noticeMessage: null);
    try {
      final content = await File(filePath).readAsString();
      final decoded = jsonDecode(content);
      final payload = decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
      final format = payload['format'];
      final isSupportedFormat =
          format == _encryptedBackupFormat ||
          _legacyEncryptedBackupFormats.contains(format);
      if (!isSupportedFormat || payload['cipherText'] is! String) {
        throw const FormatException('不是潮汐账本加密备份文件。');
      }
      final decryptedPayload = await const VaultCryptoBridge().decryptLedger(
        payload['cipherText'] as String,
        backupPassword,
      );
      final decryptedJson = jsonDecode(decryptedPayload);
      final bookPayload = decryptedJson is Map<String, dynamic>
          ? decryptedJson['book'] is Map
                ? Map<String, dynamic>.from(decryptedJson['book'] as Map)
                : decryptedJson
          : Map<String, dynamic>.from(decryptedJson as Map);
      final importedBook = LedgerBook.fromJson(bookPayload)
          .withoutLegacySeedData()
          .migrateAutoCapturedUtcTimes()
          .backfillAutoCaptureCounterpartyNames()
          .normalizeShoppingAutoCaptureTitles()
          .copyWith(updatedAt: DateTime.now());
      await _persistBook(
        importedBook,
        passphrase,
        notice: '加密备份已导入，当前内容已替换为导入版本。',
      );
      if (identical(state.book, importedBook)) {
        await _syncBiometricPassphrase(importedBook.settings, passphrase);
      }
    } catch (error) {
      state = state.copyWith(
        busy: false,
        errorMessage: '导入失败：备份密码不正确、文件已损坏，或文件不是潮汐账本加密备份。错误：$error',
      );
    }
  }
}

class LedgerVaultRepository {
  const LedgerVaultRepository(this._bridge);

  final VaultCryptoBridge _bridge;

  Future<Directory> _vaultDirectory() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _vaultFile() async {
    final directory = await _vaultDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_ledgerFileName');
  }

  Future<File> _legacyVaultFile() async {
    final directory = await _vaultDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}$_legacyLedgerFileName',
    );
  }

  Future<File> _readableVaultFile() async {
    final file = await _vaultFile();
    if (await file.exists()) {
      return file;
    }
    return _legacyVaultFile();
  }

  Future<bool> vaultExists() async {
    final file = await _vaultFile();
    if (await file.exists()) {
      return true;
    }
    final legacyFile = await _legacyVaultFile();
    return legacyFile.exists();
  }

  Future<void> save(LedgerBook book, String passphrase) async {
    final file = await _vaultFile();
    final payload = jsonEncode(book.toJson());
    final cipher = await _bridge.encryptLedger(payload, passphrase);
    await file.writeAsString(cipher, flush: true);
    final legacyFile = await _legacyVaultFile();
    if (legacyFile.path != file.path && await legacyFile.exists()) {
      await legacyFile.delete();
    }
  }

  Future<LedgerBook> load(String passphrase) async {
    final file = await _readableVaultFile();
    final cipher = await file.readAsString();
    final jsonString = await _bridge.decryptLedger(cipher, passphrase);
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    final book = LedgerBook.fromJson(decoded);
    final activeFile = await _vaultFile();
    if (!cipher.startsWith(_vaultCipherPrefix) ||
        file.path != activeFile.path) {
      await save(book, passphrase);
    }
    return book;
  }

  Future<void> deleteVault() async {
    final file = await _vaultFile();
    if (await file.exists()) await file.delete();
    final legacyFile = await _legacyVaultFile();
    if (await legacyFile.exists()) await legacyFile.delete();
  }
}

class VaultCryptoBridge {
  const VaultCryptoBridge();

  static const _channel = MethodChannel('com.aline.jier/vault_crypto');

  Future<String> encryptLedger(String payload, String passphrase) async {
    if (!Platform.isAndroid) {
      return '$_vaultCipherPrefix${base64Encode(utf8.encode(payload))}';
    }

    return (await _channel.invokeMethod<String>('encryptLedger', {
          'payload': payload,
          'passphrase': passphrase,
        })) ??
        '';
  }

  Future<String> decryptLedger(String cipherText, String passphrase) async {
    if (!Platform.isAndroid) {
      final normalized = cipherText.startsWith(_vaultCipherPrefix)
          ? cipherText.substring(_vaultCipherPrefix.length)
          : cipherText;
      return utf8.decode(base64Decode(normalized));
    }

    final result = await _channel.invokeMethod<String>('decryptLedger', {
      'payload': cipherText,
      'passphrase': passphrase,
    });
    if (result == null) {
      throw StateError('解密返回为空。');
    }
    return result;
  }
}

class AndroidAutoCaptureBridge {
  const AndroidAutoCaptureBridge();

  static const _channel = MethodChannel('com.aline.jier/auto_capture');

  Future<bool> isNotificationAccessEnabled() async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('isNotificationAccessEnabled')) ??
        false;
  }

  Future<void> openNotificationAccessSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openNotificationAccessSettings');
  }

  Future<List<AutoCaptureRecord>> fetchPendingRecords() async {
    if (!Platform.isAndroid) return const [];
    final raw =
        await _channel.invokeMethod<List<dynamic>>('fetchPendingAutoRecords') ??
        const [];
    return raw
        .whereType<Map>()
        .map(
          (map) => AutoCaptureRecord.fromJson(Map<String, dynamic>.from(map)),
        )
        .toList();
  }

  Future<void> acknowledgeRecords(List<AutoCaptureRecord> records) async {
    if (!Platform.isAndroid || records.isEmpty) return;
    await _channel.invokeMethod<void>('acknowledgeAutoRecords', {
      'records': [
        for (final record in records)
          {
            'id': record.id,
            'rawBody': record.rawBody,
            'detailSummary': record.detailSummary,
            'amount': record.amount,
          },
      ],
    });
  }

  /// 通知原文收件箱：用来核对"收到什么 → 记成了什么"。
  Future<List<RawNotificationRecord>> fetchRawNotifications({
    int limit = 60,
  }) async {
    if (!Platform.isAndroid) return const [];
    final raw =
        await _channel.invokeMethod<List<dynamic>>('fetchRawNotifications', {
          'limit': limit,
        }) ??
        const [];
    return raw
        .whereType<Map>()
        .map(
          (map) =>
              RawNotificationRecord.fromJson(Map<String, dynamic>.from(map)),
        )
        .toList();
  }

  Future<void> clearRawNotifications() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('clearRawNotifications');
  }

  /// 自动记账管道的运行情况（待处理、已解析、丢弃条数）。
  Future<AutoCapturePipelineStats> fetchStats() async {
    if (!Platform.isAndroid) return AutoCapturePipelineStats.empty;
    final map = await _channel.invokeMapMethod<String, dynamic>(
      'autoCaptureStats',
    );
    return AutoCapturePipelineStats.fromMap(map ?? const {});
  }

  /// #15 后台常驻：队列里还有货时把进程留住，队列清空就停掉，不白耗电。
  Future<void> startDrainService(int pending) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('startCaptureDrain', {
        'pending': pending,
      });
    } catch (_) {
      // 老系统/权限受限时静默失败，不影响前台记账。
    }
  }

  Future<void> stopDrainService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopCaptureDrain');
    } catch (_) {}
  }
}

class AndroidWindowPrivacyBridge {
  const AndroidWindowPrivacyBridge();

  static const _channel = MethodChannel('com.aline.jier/window_privacy');

  Future<bool> isScreenCaptureAllowed() async {
    if (!Platform.isAndroid) return true;
    return (await _channel.invokeMethod<bool>('isScreenCaptureAllowed')) ??
        true;
  }

  Future<void> setScreenCaptureAllowed(
    bool allowed, {
    bool persist = true,
  }) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setScreenCaptureAllowed', {
      'allowed': allowed,
      'persist': persist,
    });
  }
}

class BiometricVaultBridge {
  BiometricVaultBridge()
    : _localAuth = LocalAuthentication(),
      _secureStorage = const FlutterSecureStorage(
        aOptions: AndroidOptions(
          encryptedSharedPreferences: true,
          resetOnError: true,
        ),
      );

  const BiometricVaultBridge.test({
    required LocalAuthentication localAuth,
    required FlutterSecureStorage secureStorage,
  }) : _localAuth = localAuth,
       _secureStorage = secureStorage;

  static const _passphraseKey = 'vault_biometric_passphrase';

  final LocalAuthentication _localAuth;
  final FlutterSecureStorage _secureStorage;

  Future<bool> isBiometricAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      final supported = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      if (!supported && !canCheck) return false;
      final available = await _localAuth.getAvailableBiometrics();
      return available.isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> authenticate() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _localAuth.authenticate(
        localizedReason: '使用指纹或生物识别解锁潮汐账本保险库',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
        sensitiveTransaction: true,
      );
    } on PlatformException {
      return false;
    }
  }

  Future<void> savePassphrase(String passphrase) async {
    if (!Platform.isAndroid) return;
    await _secureStorage.write(key: _passphraseKey, value: passphrase);
  }

  Future<String?> readPassphrase() async {
    if (!Platform.isAndroid) return null;
    return _secureStorage.read(key: _passphraseKey);
  }

  Future<void> clearPassphrase() async {
    if (!Platform.isAndroid) return;
    await _secureStorage.delete(key: _passphraseKey);
  }
}

class LedgerViewState {
  const LedgerViewState({
    required this.initializing,
    required this.onboardingRequired,
    required this.locked,
    required this.busy,
    required this.notificationAccessGranted,
    required this.biometricAvailable,
    required this.revealAmounts,
    required this.canUseShell,
    this.book,
    this.errorMessage,
    this.noticeMessage,
    this.lastAutoSyncAt,
  });

  factory LedgerViewState.initial() => const LedgerViewState(
    initializing: true,
    onboardingRequired: false,
    locked: true,
    busy: false,
    notificationAccessGranted: false,
    biometricAvailable: false,
    revealAmounts: false,
    canUseShell: false,
  );

  final bool initializing;
  final bool onboardingRequired;
  final bool locked;
  final bool busy;
  final bool notificationAccessGranted;
  final bool biometricAvailable;
  final bool revealAmounts;
  final bool canUseShell;
  final LedgerBook? book;
  final String? errorMessage;
  final String? noticeMessage;
  final DateTime? lastAutoSyncAt;

  bool get canShowShell =>
      !initializing && !onboardingRequired && !locked && book != null;

  LedgerViewState copyWith({
    bool? initializing,
    bool? onboardingRequired,
    bool? locked,
    bool? busy,
    bool? notificationAccessGranted,
    bool? biometricAvailable,
    bool? revealAmounts,
    bool? canUseShell,
    LedgerBook? book,
    Object? errorMessage = _unset,
    Object? noticeMessage = _unset,
    DateTime? lastAutoSyncAt,
  }) {
    return LedgerViewState(
      initializing: initializing ?? this.initializing,
      onboardingRequired: onboardingRequired ?? this.onboardingRequired,
      locked: locked ?? this.locked,
      busy: busy ?? this.busy,
      notificationAccessGranted:
          notificationAccessGranted ?? this.notificationAccessGranted,
      biometricAvailable: biometricAvailable ?? this.biometricAvailable,
      revealAmounts: revealAmounts ?? this.revealAmounts,
      canUseShell: canUseShell ?? this.canUseShell,
      book: book ?? this.book,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
      noticeMessage: noticeMessage == _unset
          ? this.noticeMessage
          : noticeMessage as String?,
      lastAutoSyncAt: lastAutoSyncAt ?? this.lastAutoSyncAt,
    );
  }
}

enum EntryType {
  expense('支出'),
  income('收入'),
  transfer('转移');

  const EntryType(this.label);

  final String label;
}

enum PaymentChannel {
  cash('现金'),
  bankCard('银行卡'),
  wechatPay('微信支付'),
  alipay('支付宝'),
  googlePay('Google Pay'),
  savings('储蓄'),
  other('其他');

  const PaymentChannel(this.label);

  final String label;
}

enum CaptureSource {
  wechat('微信'),
  alipay('支付宝'),
  googlePay('Google Pay'),
  taobao('淘宝'),
  jd('京东'),
  pinduoduo('拼多多'),
  xianyu('闲鱼'),
  bank('银行卡'),
  unknown('未知');

  const CaptureSource(this.label);

  final String label;

  bool get isPaymentSource =>
      this == CaptureSource.wechat ||
      this == CaptureSource.alipay ||
      this == CaptureSource.googlePay;

  bool get isShoppingSource =>
      this == CaptureSource.taobao ||
      this == CaptureSource.jd ||
      this == CaptureSource.pinduoduo ||
      this == CaptureSource.xianyu;

  static CaptureSource fromNameOrUnknown(String? value) {
    for (final item in CaptureSource.values) {
      if (item.name == value) {
        return item;
      }
    }
    return CaptureSource.unknown;
  }

  static CaptureSource fromLabelOrUnknown(String? label) {
    for (final item in CaptureSource.values) {
      if (item.label == label) {
        return item;
      }
    }
    return CaptureSource.unknown;
  }
}

class AppCategory {
  const AppCategory({
    required this.id,
    required this.name,
    required this.pillar,
    required this.type,
    required this.icon,
    required this.color,
    required this.keywords,
  });

  final String id;
  final String name;
  final String pillar;
  final EntryType type;
  final IconData icon;
  final Color color;
  final List<String> keywords;
}

const appCategories = <AppCategory>[
  AppCategory(
    id: 'daily',
    name: '日常消费',
    pillar: '日常',
    type: EntryType.expense,
    icon: Icons.wb_sunny_outlined,
    color: Color(0xFF4E8DFF),
    keywords: ['便利店', '日用', '杂货', '商店', '超市', '生活', 'daily'],
  ),
  AppCategory(
    id: 'food',
    name: '餐饮',
    pillar: '日常',
    type: EntryType.expense,
    icon: Icons.ramen_dining_rounded,
    color: Color(0xFFFD8D53),
    keywords: ['coffee', 'starbucks', '餐', '外卖', '咖啡', '茶饮', '美团', '饿了么'],
  ),
  AppCategory(
    id: 'housing',
    name: '住房',
    pillar: '居住',
    type: EntryType.expense,
    icon: Icons.home_rounded,
    color: Color(0xFF6A7BFF),
    keywords: ['房租', '租金', '租房', '房贷', '物业', '电费', '燃气', '水费'],
  ),
  AppCategory(
    id: 'mobility',
    name: '出行',
    pillar: '通勤',
    type: EntryType.expense,
    icon: Icons.directions_bus_filled_rounded,
    color: Color(0xFF0FA968),
    keywords: ['滴滴', '地铁', '公交', '打车', 'fuel', 'petrol', 'uber'],
  ),
  AppCategory(
    id: 'shopping',
    name: '购物',
    pillar: '消费',
    type: EntryType.expense,
    icon: Icons.shopping_bag_rounded,
    color: Color(0xFFCA5CFF),
    keywords: [
      '淘宝',
      '京东',
      '京東',
      '拼多多',
      '闲鱼',
      '閒魚',
      'mall',
      'store',
      '超市',
      'shop',
    ],
  ),
  AppCategory(
    id: 'health',
    name: '健康',
    pillar: '照护',
    type: EntryType.expense,
    icon: Icons.favorite_rounded,
    color: Color(0xFFF44D63),
    keywords: ['医院', '药', 'clinic', 'dent', '医', 'pharmacy'],
  ),
  AppCategory(
    id: 'education',
    name: '学习',
    pillar: '成长',
    type: EntryType.expense,
    icon: Icons.school_rounded,
    color: Color(0xFF4A78F2),
    keywords: ['课程', '教材', 'book', 'udemy', 'class', '培训'],
  ),
  AppCategory(
    id: 'family',
    name: '家庭',
    pillar: '家庭',
    type: EntryType.expense,
    icon: Icons.family_restroom_rounded,
    color: Color(0xFFAB845A),
    keywords: [
      '家人',
      '家庭',
      '家用',
      '亲子',
      '宝宝',
      '母婴',
      '育儿',
      'parents',
      'family',
    ],
  ),
  AppCategory(
    id: 'pets',
    name: '宠物',
    pillar: '家庭',
    type: EntryType.expense,
    icon: Icons.pets_rounded,
    color: Color(0xFF4CB3A7),
    keywords: ['宠物', 'pet', '猫粮', '猫砂', '狗粮', '狗狗'],
  ),
  AppCategory(
    id: 'travel',
    name: '旅行',
    pillar: '体验',
    type: EntryType.expense,
    icon: Icons.flight_takeoff_rounded,
    color: Color(0xFF2783F3),
    keywords: ['酒店', 'trip', 'travel', 'air', 'rail', '旅游'],
  ),
  AppCategory(
    id: 'entertainment',
    name: '娱乐',
    pillar: '体验',
    type: EntryType.expense,
    icon: Icons.music_note_rounded,
    color: Color(0xFF7E67E7),
    keywords: ['movie', '音乐', '演出', '娱乐', 'game'],
  ),
  AppCategory(
    id: 'digital',
    name: '数码服务',
    pillar: '效率',
    type: EntryType.expense,
    icon: Icons.cloud_done_rounded,
    color: Color(0xFF2878B8),
    keywords: ['icloud', 'google', 'drive', 'spotify', 'netflix', 'apple'],
  ),
  AppCategory(
    id: 'fitness',
    name: '运动',
    pillar: '照护',
    type: EntryType.expense,
    icon: Icons.sports_gymnastics_rounded,
    color: Color(0xFF23967F),
    keywords: ['gym', '健身', '运动', '瑜伽'],
  ),
  AppCategory(
    id: 'salary',
    name: '工资',
    pillar: '现金流',
    type: EntryType.income,
    icon: Icons.payments_rounded,
    color: Color(0xFF199C5E),
    keywords: ['工资', 'salary', 'payroll'],
  ),
  AppCategory(
    id: 'bonus',
    name: '奖金',
    pillar: '现金流',
    type: EntryType.income,
    icon: Icons.auto_awesome_rounded,
    color: Color(0xFFFFB326),
    keywords: ['bonus', '奖金', '绩效'],
  ),
  AppCategory(
    id: 'freelance',
    name: '副业',
    pillar: '现金流',
    type: EntryType.income,
    icon: Icons.laptop_mac_rounded,
    color: Color(0xFF5D74FF),
    keywords: ['稿费', 'consulting', 'project', 'freelance'],
  ),
  AppCategory(
    id: 'investment',
    name: '投资',
    pillar: '增长',
    type: EntryType.income,
    icon: Icons.trending_up_rounded,
    color: Color(0xFF16A085),
    keywords: ['dividend', '理财', '利息', 'investment'],
  ),
];

AppCategory categoryForId(String id) => appCategories.firstWhere(
  (category) => category.id == id,
  orElse: () => appCategories.first,
);

List<AppCategory> categoriesForType(EntryType type) =>
    appCategories.where((category) => category.type == type).toList();

bool _isValidCategoryIdForType(String id, EntryType type) =>
    appCategories.any((category) => category.id == id && category.type == type);

String resolveDefaultExpenseCategoryId(VaultSettings settings) {
  if (_isValidCategoryIdForType(
    settings.defaultExpenseCategoryId,
    EntryType.expense,
  )) {
    return settings.defaultExpenseCategoryId;
  }
  if (_isValidCategoryIdForType('daily', EntryType.expense)) {
    return 'daily';
  }
  return categoriesForType(EntryType.expense).first.id;
}

String _fallbackCategoryIdForType(EntryType type) {
  if (type == EntryType.expense &&
      _isValidCategoryIdForType('daily', EntryType.expense)) {
    return 'daily';
  }
  return categoriesForType(type).first.id;
}

enum LocationTrackingMode { off, foregroundLazy, backgroundPrecise, ipRough }

enum AssetType { wechat, alipay, bankCard, cash, other }

class FavoriteLocation {
  const FavoriteLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.categoryId,
    this.defaultTitle,
    this.defaultAmount,
  });

  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String? categoryId;
  final String? defaultTitle;
  final double? defaultAmount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'latitude': latitude,
    'longitude': longitude,
    'categoryId': categoryId,
    'defaultTitle': defaultTitle,
    'defaultAmount': defaultAmount,
  };

  factory FavoriteLocation.fromJson(Map<String, dynamic> json) =>
      FavoriteLocation(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        categoryId: json['categoryId'] as String?,
        defaultTitle: json['defaultTitle'] as String?,
        defaultAmount: (json['defaultAmount'] as num?)?.toDouble(),
      );

  FavoriteLocation copyWith({
    String? id,
    String? name,
    String? address,
    double? latitude,
    double? longitude,
    Object? categoryId = _unset,
    Object? defaultTitle = _unset,
    Object? defaultAmount = _unset,
  }) {
    return FavoriteLocation(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      categoryId: categoryId == _unset
          ? this.categoryId
          : categoryId as String?,
      defaultTitle: defaultTitle == _unset
          ? this.defaultTitle
          : defaultTitle as String?,
      defaultAmount: defaultAmount == _unset
          ? this.defaultAmount
          : defaultAmount as double?,
    );
  }
}

class AssetAccount {
  const AssetAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.initialBalance,
  });

  final String id;
  final String name;
  final AssetType type;
  final double initialBalance;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'initialBalance': initialBalance,
  };

  factory AssetAccount.fromJson(Map<String, dynamic> json) => AssetAccount(
    id: json['id'] as String,
    name: json['name'] as String,
    type: AssetType.values.byName(json['type'] as String),
    initialBalance: (json['initialBalance'] as num).toDouble(),
  );
}

class CategorizationRule {
  const CategorizationRule({
    required this.id,
    required this.pattern,
    required this.categoryId,
    required this.autoTags,
  });

  final String id;
  final String pattern;
  final String categoryId;
  final List<String> autoTags;

  Map<String, dynamic> toJson() => {
    'id': id,
    'pattern': pattern,
    'categoryId': categoryId,
    'autoTags': autoTags,
  };

  factory CategorizationRule.fromJson(Map<String, dynamic> json) =>
      CategorizationRule(
        id: json['id'] as String,
        pattern: json['pattern'] as String,
        categoryId: json['categoryId'] as String,
        autoTags: (json['autoTags'] as List<dynamic>? ?? const [])
            .cast<String>(),
      );
}

enum ExpenseMood {
  none('无心情', '😐', Color(0xFF9E9E9E)),
  angry('冲动解压', '😡', Color(0xFFF44336)),
  happy('开心庆祝', '🎉', Color(0xFFFF9800)),
  tired('疲惫犒劳', '☕', Color(0xFF795548)),
  sad('emo抚慰', '🌧️', Color(0xFF2196F3)),
  chill('平静松弛', '🧘', Color(0xFF009688));

  final String label;
  final String emoji;
  final Color color;
  const ExpenseMood(this.label, this.emoji, this.color);
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.title,
    required this.merchant,
    this.counterpartyName = '',
    required this.note,
    required this.amount,
    required this.type,
    required this.categoryId,
    required this.channel,
    required this.occurredAt,
    this.tags = const [],
    this.linkedRefundEntryIds = const [],
    this.locationInfo = '',
    this.latitude,
    this.longitude,
    this.mood = ExpenseMood.none,
    required this.autoCaptured,
    required this.sourceLabel,
    this.autoMergeKey = '',
    this.autoProfileId = -1,
    this.autoPostedAtMillis = -1,
    this.manualOverrideFields = const [],
    this.fundingAccount = '',
    this.inferredFields = const {},
  });

  final String id;
  final String title;
  final String merchant;
  final String counterpartyName;
  final String note;
  final double amount;
  final EntryType type;
  final String categoryId;
  final PaymentChannel channel;
  final DateTime occurredAt;
  final List<String> tags;
  final List<String> linkedRefundEntryIds;
  final String locationInfo;
  final double? latitude;
  final double? longitude;
  final ExpenseMood mood;
  final bool autoCaptured;
  final String sourceLabel;

  /// 资金来源账户，例如"招商银行 ••8821"。
  /// 商户、支付渠道、资金来源是三件事：淘宝 / 微信支付 / 招商银行••8821。
  final String fundingAccount;

  /// #8：哪些字段是**推测**（千问判断）而不是通知里的事实。
  /// FACT（金额/时间/收支/账户）永不重写；将来换更好的模型时只重跑这里面的字段。
  final Set<String> inferredFields;

  final String autoMergeKey;
  final int autoProfileId;
  final int autoPostedAtMillis;
  final List<String> manualOverrideFields;

  LedgerEntry copyWith({
    String? id,
    String? title,
    String? merchant,
    String? counterpartyName,
    String? note,
    double? amount,
    EntryType? type,
    String? categoryId,
    PaymentChannel? channel,
    DateTime? occurredAt,
    List<String>? tags,
    List<String>? linkedRefundEntryIds,
    String? locationInfo,
    double? latitude,
    double? longitude,
    ExpenseMood? mood,
    bool? autoCaptured,
    String? sourceLabel,
    String? autoMergeKey,
    int? autoProfileId,
    int? autoPostedAtMillis,
    List<String>? manualOverrideFields,
    String? fundingAccount,
    Set<String>? inferredFields,
  }) {
    return LedgerEntry(
      id: id ?? this.id,
      title: title ?? this.title,
      merchant: merchant ?? this.merchant,
      counterpartyName: counterpartyName ?? this.counterpartyName,
      note: note ?? this.note,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      categoryId: categoryId ?? this.categoryId,
      channel: channel ?? this.channel,
      occurredAt: occurredAt ?? this.occurredAt,
      tags: tags ?? this.tags,
      linkedRefundEntryIds: linkedRefundEntryIds ?? this.linkedRefundEntryIds,
      locationInfo: locationInfo ?? this.locationInfo,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      mood: mood ?? this.mood,
      autoCaptured: autoCaptured ?? this.autoCaptured,
      sourceLabel: sourceLabel ?? this.sourceLabel,
      autoMergeKey: autoMergeKey ?? this.autoMergeKey,
      autoProfileId: autoProfileId ?? this.autoProfileId,
      autoPostedAtMillis: autoPostedAtMillis ?? this.autoPostedAtMillis,
      fundingAccount: fundingAccount ?? this.fundingAccount,
      manualOverrideFields: manualOverrideFields ?? this.manualOverrideFields,
      inferredFields: inferredFields ?? this.inferredFields,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'merchant': merchant,
    'counterpartyName': counterpartyName,
    'note': note,
    'amount': amount,
    'type': type.name,
    'categoryId': categoryId,
    'channel': channel.name,
    'occurredAt': occurredAt.toIso8601String(),
    'tags': tags,
    'linkedRefundEntryIds': linkedRefundEntryIds,
    'locationInfo': locationInfo,
    'latitude': latitude,
    'longitude': longitude,
    'mood': mood.name,
    'autoCaptured': autoCaptured,
    'sourceLabel': sourceLabel,
    'fundingAccount': fundingAccount,
    'inferredFields': inferredFields.toList(),
    'autoMergeKey': autoMergeKey,
    'autoProfileId': autoProfileId,
    'autoPostedAtMillis': autoPostedAtMillis,
    'manualOverrideFields': manualOverrideFields,
  };

  factory LedgerEntry.fromJson(Map<String, dynamic> json) => LedgerEntry(
    id: json['id'] as String,
    title: json['title'] as String,
    merchant: json['merchant'] as String,
    counterpartyName: json['counterpartyName'] as String? ?? '',
    note: json['note'] as String? ?? '',
    amount: (json['amount'] as num).toDouble(),
    type: EntryType.values.byName(json['type'] as String),
    categoryId: json['categoryId'] as String,
    channel: PaymentChannel.values.byName(json['channel'] as String),
    occurredAt: DateTime.parse(json['occurredAt'] as String),
    tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
    linkedRefundEntryIds:
        (json['linkedRefundEntryIds'] as List<dynamic>? ?? const [])
            .cast<String>(),
    locationInfo: json['locationInfo'] as String? ?? '',
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    mood: ExpenseMood.values.firstWhere(
      (e) => e.name == json['mood'],
      orElse: () => ExpenseMood.none,
    ),
    autoCaptured: json['autoCaptured'] as bool? ?? false,
    sourceLabel: json['sourceLabel'] as String? ?? '',
    fundingAccount: json['fundingAccount'] as String? ?? '',
    inferredFields:
        (json['inferredFields'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toSet(),
    autoMergeKey: json['autoMergeKey'] as String? ?? '',
    autoProfileId: (json['autoProfileId'] as num?)?.toInt() ?? -1,
    autoPostedAtMillis:
        (json['autoPostedAtMillis'] as num?)?.toInt() ??
        DateTime.parse(json['occurredAt'] as String).millisecondsSinceEpoch,
    manualOverrideFields:
        (json['manualOverrideFields'] as List<dynamic>? ?? const [])
            .cast<String>(),
  );
}

class LedgerPeriod {
  const LedgerPeriod({
    required this.id,
    required this.name,
    required this.startAt,
    required this.endAt,
    this.note = '',
  });

  final String id;
  final String name;
  final DateTime startAt;
  final DateTime endAt;
  final String note;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'startAt': startAt.toIso8601String(),
    'endAt': endAt.toIso8601String(),
    'note': note,
  };

  factory LedgerPeriod.fromJson(Map<String, dynamic> json) => LedgerPeriod(
    id: json['id'] as String,
    name: json['name'] as String,
    startAt: DateTime.parse(json['startAt'] as String),
    endAt: DateTime.parse(json['endAt'] as String),
    note: json['note'] as String? ?? '',
  );
}

class BudgetEnvelope {
  const BudgetEnvelope({
    required this.id,
    required this.categoryId,
    required this.monthlyLimit,
    required this.targetLabel,
  });

  final String id;
  final String categoryId;
  final double monthlyLimit;
  final String targetLabel;

  Map<String, dynamic> toJson() => {
    'id': id,
    'categoryId': categoryId,
    'monthlyLimit': monthlyLimit,
    'targetLabel': targetLabel,
  };

  factory BudgetEnvelope.fromJson(Map<String, dynamic> json) => BudgetEnvelope(
    id: json['id'] as String,
    categoryId: json['categoryId'] as String,
    monthlyLimit: (json['monthlyLimit'] as num).toDouble(),
    targetLabel: json['targetLabel'] as String,
  );
}

class SavingsGoal {
  const SavingsGoal({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.currentAmount,
    required this.dueDate,
    required this.focusLabel,
  });

  final String id;
  final String name;
  final double targetAmount;
  final double currentAmount;
  final DateTime dueDate;
  final String focusLabel;

  double get progress =>
      targetAmount == 0 ? 0 : (currentAmount / targetAmount).clamp(0, 1);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'targetAmount': targetAmount,
    'currentAmount': currentAmount,
    'dueDate': dueDate.toIso8601String(),
    'focusLabel': focusLabel,
  };

  factory SavingsGoal.fromJson(Map<String, dynamic> json) => SavingsGoal(
    id: json['id'] as String,
    name: json['name'] as String,
    targetAmount: (json['targetAmount'] as num).toDouble(),
    currentAmount: (json['currentAmount'] as num).toDouble(),
    dueDate: DateTime.parse(json['dueDate'] as String),
    focusLabel: json['focusLabel'] as String,
  );
}

class RecurringPlan {
  const RecurringPlan({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.amount,
    required this.cycleDays,
    required this.nextChargeAt,
    required this.channel,
  });

  final String id;
  final String name;
  final String categoryId;
  final double amount;
  final int cycleDays;
  final DateTime nextChargeAt;
  final PaymentChannel channel;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'categoryId': categoryId,
    'amount': amount,
    'cycleDays': cycleDays,
    'nextChargeAt': nextChargeAt.toIso8601String(),
    'channel': channel.name,
  };

  factory RecurringPlan.fromJson(Map<String, dynamic> json) => RecurringPlan(
    id: json['id'] as String,
    name: json['name'] as String,
    categoryId: json['categoryId'] as String,
    amount: (json['amount'] as num).toDouble(),
    cycleDays: json['cycleDays'] as int,
    nextChargeAt: DateTime.parse(json['nextChargeAt'] as String),
    channel: PaymentChannel.values.byName(json['channel'] as String),
  );
}

class VaultSettings {
  const VaultSettings({
    required this.confidentialModeEnabled,
    required this.maskAmounts,
    required this.quickLockOnBackground,
    required this.allowScreenshots,
    required this.biometricUnlockEnabled,
    required this.autoCaptureEnabled,
    required this.defaultExpenseCategoryId,
    required this.wechatEnabled,
    required this.alipayEnabled,
    required this.googlePayEnabled,
    required this.taobaoEnabled,
    required this.jdEnabled,
    required this.pinduoduoEnabled,
    required this.xianyuEnabled,
    required this.bankEnabled,
    this.aiCaptureSpec = defaultAiCaptureSpec,
    this.voiceInputEnabled = true,
    this.locationMode = LocationTrackingMode.off,
    this.autoRecordLocation = false,
    this.localAiModelId = 'qwen3-06b-q4',
    this.autoAiCaptureEnabled = false,
  });

  final bool confidentialModeEnabled;
  final bool maskAmounts;
  final bool quickLockOnBackground;
  final bool allowScreenshots;
  final bool biometricUnlockEnabled;
  final bool autoCaptureEnabled;
  final String defaultExpenseCategoryId;
  final bool wechatEnabled;
  final bool alipayEnabled;
  final bool googlePayEnabled;
  final bool taobaoEnabled;
  final bool jdEnabled;
  final bool pinduoduoEnabled;
  final bool xianyuEnabled;
  final bool bankEnabled;

  /// 让千问按什么风格生成账单字段，用户可以在设置里改。
  final String aiCaptureSpec;
  final bool voiceInputEnabled;
  final LocationTrackingMode locationMode;
  final bool autoRecordLocation;
  final String localAiModelId;
  final bool autoAiCaptureEnabled;

  Map<String, dynamic> toJson() => {
    'confidentialModeEnabled': confidentialModeEnabled,
    'maskAmounts': maskAmounts,
    'quickLockOnBackground': quickLockOnBackground,
    'allowScreenshots': allowScreenshots,
    'biometricUnlockEnabled': biometricUnlockEnabled,
    'autoCaptureEnabled': autoCaptureEnabled,
    'defaultExpenseCategoryId': defaultExpenseCategoryId,
    'wechatEnabled': wechatEnabled,
    'alipayEnabled': alipayEnabled,
    'googlePayEnabled': googlePayEnabled,
    'taobaoEnabled': taobaoEnabled,
    'jdEnabled': jdEnabled,
    'pinduoduoEnabled': pinduoduoEnabled,
    'xianyuEnabled': xianyuEnabled,
    'bankEnabled': bankEnabled,
    'aiCaptureSpec': aiCaptureSpec,
    'voiceInputEnabled': voiceInputEnabled,
    'locationMode': locationMode.name,
    'autoRecordLocation': autoRecordLocation,
    'localAiModelId': localAiModelId,
    'autoAiCaptureEnabled': autoAiCaptureEnabled,
  };

  factory VaultSettings.fromJson(Map<String, dynamic> json) => VaultSettings(
    confidentialModeEnabled: json['confidentialModeEnabled'] as bool? ?? true,
    maskAmounts: json['maskAmounts'] as bool? ?? true,
    quickLockOnBackground: json['quickLockOnBackground'] as bool? ?? true,
    allowScreenshots: json['allowScreenshots'] as bool? ?? true,
    biometricUnlockEnabled: json['biometricUnlockEnabled'] as bool? ?? false,
    autoCaptureEnabled: json['autoCaptureEnabled'] as bool? ?? true,
    defaultExpenseCategoryId:
        json['defaultExpenseCategoryId'] as String? ?? 'daily',
    wechatEnabled: json['wechatEnabled'] as bool? ?? true,
    alipayEnabled: json['alipayEnabled'] as bool? ?? true,
    googlePayEnabled: json['googlePayEnabled'] as bool? ?? true,
    taobaoEnabled: json['taobaoEnabled'] as bool? ?? true,
    jdEnabled: json['jdEnabled'] as bool? ?? true,
    pinduoduoEnabled: json['pinduoduoEnabled'] as bool? ?? true,
    xianyuEnabled: json['xianyuEnabled'] as bool? ?? true,
    bankEnabled: json['bankEnabled'] as bool? ?? true,
    aiCaptureSpec: json['aiCaptureSpec'] as String? ?? defaultAiCaptureSpec,
    voiceInputEnabled: json['voiceInputEnabled'] as bool? ?? true,
    locationMode: LocationTrackingMode.values.firstWhere(
      (e) => e.name == (json['locationMode'] as String?),
      orElse: () => LocationTrackingMode.off,
    ),
    autoRecordLocation: json['autoRecordLocation'] as bool? ?? false,
    localAiModelId: json['localAiModelId'] as String? ?? 'qwen3-06b-q4',
    autoAiCaptureEnabled: json['autoAiCaptureEnabled'] as bool? ?? false,
  );

  VaultSettings copyWith({
    bool? confidentialModeEnabled,
    bool? maskAmounts,
    bool? quickLockOnBackground,
    bool? allowScreenshots,
    bool? biometricUnlockEnabled,
    bool? autoCaptureEnabled,
    String? defaultExpenseCategoryId,
    bool? wechatEnabled,
    bool? alipayEnabled,
    bool? googlePayEnabled,
    bool? taobaoEnabled,
    bool? jdEnabled,
    bool? pinduoduoEnabled,
    bool? xianyuEnabled,
    bool? bankEnabled,
    String? aiCaptureSpec,
    bool? voiceInputEnabled,
    LocationTrackingMode? locationMode,
    bool? autoRecordLocation,
    String? localAiModelId,
    bool? autoAiCaptureEnabled,
  }) {
    return VaultSettings(
      confidentialModeEnabled:
          confidentialModeEnabled ?? this.confidentialModeEnabled,
      maskAmounts: maskAmounts ?? this.maskAmounts,
      quickLockOnBackground:
          quickLockOnBackground ?? this.quickLockOnBackground,
      allowScreenshots: allowScreenshots ?? this.allowScreenshots,
      biometricUnlockEnabled:
          biometricUnlockEnabled ?? this.biometricUnlockEnabled,
      autoCaptureEnabled: autoCaptureEnabled ?? this.autoCaptureEnabled,
      defaultExpenseCategoryId:
          defaultExpenseCategoryId ?? this.defaultExpenseCategoryId,
      wechatEnabled: wechatEnabled ?? this.wechatEnabled,
      alipayEnabled: alipayEnabled ?? this.alipayEnabled,
      googlePayEnabled: googlePayEnabled ?? this.googlePayEnabled,
      taobaoEnabled: taobaoEnabled ?? this.taobaoEnabled,
      jdEnabled: jdEnabled ?? this.jdEnabled,
      pinduoduoEnabled: pinduoduoEnabled ?? this.pinduoduoEnabled,
      xianyuEnabled: xianyuEnabled ?? this.xianyuEnabled,
      bankEnabled: bankEnabled ?? this.bankEnabled,
      aiCaptureSpec: aiCaptureSpec ?? this.aiCaptureSpec,
      voiceInputEnabled: voiceInputEnabled ?? this.voiceInputEnabled,
      locationMode: locationMode ?? this.locationMode,
      autoRecordLocation: autoRecordLocation ?? this.autoRecordLocation,
      localAiModelId: localAiModelId ?? this.localAiModelId,
      autoAiCaptureEnabled: autoAiCaptureEnabled ?? this.autoAiCaptureEnabled,
    );
  }
}

class LedgerBook {
  const LedgerBook({
    required this.createdAt,
    required this.updatedAt,
    required this.entries,
    this.periods = const [],
    required this.budgets,
    required this.goals,
    required this.subscriptions,
    required this.settings,
    this.assetAccounts = const [],
    this.customRules = const [],
    this.favoriteLocations = const [],
    this.aiMessages = const [],
    this.aiFocusEntryIds = const [],
    this.merchantCategories = const {},
    this.captureTemplates = const {},
    this.capturePathStats = const {},
    this.captureDelayProfile = const {},
    this.captureSequence = const {},
  });

  factory LedgerBook.empty(bool confidentialModeEnabled) {
    final now = DateTime.now();
    return LedgerBook(
      createdAt: now,
      updatedAt: now,
      entries: const [],
      periods: const [],
      budgets: const [],
      goals: const [],
      subscriptions: const [],
      assetAccounts: const [],
      customRules: [
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '瑞幸',
          categoryId: 'food',
          autoTags: ['下午茶', '咖啡'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '喜茶',
          categoryId: 'food',
          autoTags: ['下午茶', '奶茶'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '星巴克',
          categoryId: 'food',
          autoTags: ['下午茶', '咖啡'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '淘宝',
          categoryId: 'shopping',
          autoTags: [],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '饿了么',
          categoryId: 'food',
          autoTags: ['外卖'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '滴滴',
          categoryId: 'mobility',
          autoTags: ['打车'],
        ),
      ],
      settings: VaultSettings(
        confidentialModeEnabled: confidentialModeEnabled,
        maskAmounts: confidentialModeEnabled,
        quickLockOnBackground: confidentialModeEnabled,
        allowScreenshots: true,
        biometricUnlockEnabled: false,
        autoCaptureEnabled: true,
        defaultExpenseCategoryId: 'daily',
        wechatEnabled: true,
        alipayEnabled: true,
        googlePayEnabled: true,
        taobaoEnabled: true,
        jdEnabled: true,
        pinduoduoEnabled: true,
        xianyuEnabled: true,
        bankEnabled: true,
        voiceInputEnabled: true,
      ),
    );
  }

  factory LedgerBook.seeded(bool confidentialModeEnabled) {
    final now = DateTime.now();
    final entries = [
      LedgerEntry(
        id: _uuid.v4(),
        title: '晨间咖啡',
        merchant: 'Blue Bottle',
        note: '工作日前给自己一点启动能量',
        amount: 32,
        type: EntryType.expense,
        categoryId: 'food',
        channel: PaymentChannel.wechatPay,
        occurredAt: now.subtract(const Duration(hours: 4)),
        tags: const ['工作日', '提神'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '地铁通勤',
        merchant: '上海地铁',
        note: '往返公司',
        amount: 8,
        type: EntryType.expense,
        categoryId: 'mobility',
        channel: PaymentChannel.alipay,
        occurredAt: now.subtract(const Duration(hours: 7)),
        tags: const ['通勤'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '午餐轻食',
        merchant: 'Sweetgreen',
        note: '控制油盐的一餐',
        amount: 68,
        type: EntryType.expense,
        categoryId: 'food',
        channel: PaymentChannel.googlePay,
        occurredAt: now.subtract(const Duration(days: 1, hours: 1)),
        tags: const ['健康饮食'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '房租分摊',
        merchant: '室友转账',
        note: '本月房租平摊入账',
        amount: 2800,
        type: EntryType.income,
        categoryId: 'salary',
        channel: PaymentChannel.bankCard,
        occurredAt: now.subtract(const Duration(days: 2)),
        tags: const ['共享居住'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '月度工资',
        merchant: '公司薪资',
        note: '主业收入',
        amount: 16000,
        type: EntryType.income,
        categoryId: 'salary',
        channel: PaymentChannel.bankCard,
        occurredAt: DateTime(now.year, now.month, 5, 10),
        tags: const ['固定收入'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '瑜伽课程',
        merchant: 'BodyLab',
        note: '本月课程包',
        amount: 399,
        type: EntryType.expense,
        categoryId: 'fitness',
        channel: PaymentChannel.alipay,
        occurredAt: now.subtract(const Duration(days: 4)),
        tags: const ['身心管理'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '宠物体检',
        merchant: '宠颐生',
        note: '猫咪年度体检',
        amount: 460,
        type: EntryType.expense,
        categoryId: 'pets',
        channel: PaymentChannel.wechatPay,
        occurredAt: now.subtract(const Duration(days: 6)),
        tags: const ['宠物'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '自由职业项目款',
        merchant: '品牌咨询',
        note: '第二阶段尾款',
        amount: 5200,
        type: EntryType.income,
        categoryId: 'freelance',
        channel: PaymentChannel.bankCard,
        occurredAt: now.subtract(const Duration(days: 9)),
        tags: const ['副业'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '在线课程续费',
        merchant: 'Coursera',
        note: '增长学习支出',
        amount: 188,
        type: EntryType.expense,
        categoryId: 'education',
        channel: PaymentChannel.googlePay,
        occurredAt: now.subtract(const Duration(days: 11)),
        tags: const ['学习'],
        autoCaptured: false,
        sourceLabel: '',
      ),
      LedgerEntry(
        id: _uuid.v4(),
        title: '云盘年费',
        merchant: 'iCloud+',
        note: '照片和文档备份',
        amount: 68,
        type: EntryType.expense,
        categoryId: 'digital',
        channel: PaymentChannel.bankCard,
        occurredAt: now.subtract(const Duration(days: 13)),
        tags: const ['效率'],
        autoCaptured: false,
        sourceLabel: '',
      ),
    ]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    final budgets = const [
      BudgetEnvelope(
        id: 'budget-food',
        categoryId: 'food',
        monthlyLimit: 1800,
        targetLabel: '工作餐 + 周末精致吃饭',
      ),
      BudgetEnvelope(
        id: 'budget-housing',
        categoryId: 'housing',
        monthlyLimit: 4500,
        targetLabel: '房租、物业、水电',
      ),
      BudgetEnvelope(
        id: 'budget-mobility',
        categoryId: 'mobility',
        monthlyLimit: 900,
        targetLabel: '公共交通 + 打车补充',
      ),
      BudgetEnvelope(
        id: 'budget-health',
        categoryId: 'health',
        monthlyLimit: 1000,
        targetLabel: '看诊、药品、牙科',
      ),
      BudgetEnvelope(
        id: 'budget-entertainment',
        categoryId: 'entertainment',
        monthlyLimit: 1200,
        targetLabel: '电影、聚会、音乐',
      ),
      BudgetEnvelope(
        id: 'budget-education',
        categoryId: 'education',
        monthlyLimit: 900,
        targetLabel: '课程、书籍、技能提升',
      ),
    ];

    final goals = [
      SavingsGoal(
        id: 'goal-reserve',
        name: '六个月应急金',
        targetAmount: 50000,
        currentAmount: 21800,
        dueDate: now.add(const Duration(days: 240)),
        focusLabel: '安全感',
      ),
      SavingsGoal(
        id: 'goal-travel',
        name: '日本赏枫旅行',
        targetAmount: 12000,
        currentAmount: 4300,
        dueDate: now.add(const Duration(days: 150)),
        focusLabel: '体验升级',
      ),
      SavingsGoal(
        id: 'goal-home-office',
        name: '家庭办公升级',
        targetAmount: 8000,
        currentAmount: 2500,
        dueDate: now.add(const Duration(days: 120)),
        focusLabel: '生产力',
      ),
    ];

    final subscriptions = [
      RecurringPlan(
        id: 'sub-spotify',
        name: 'Spotify Premium',
        categoryId: 'entertainment',
        amount: 15,
        cycleDays: 30,
        nextChargeAt: now.add(const Duration(days: 3)),
        channel: PaymentChannel.googlePay,
      ),
      RecurringPlan(
        id: 'sub-cloud',
        name: 'iCloud+ 2TB',
        categoryId: 'digital',
        amount: 68,
        cycleDays: 30,
        nextChargeAt: now.add(const Duration(days: 5)),
        channel: PaymentChannel.bankCard,
      ),
      RecurringPlan(
        id: 'sub-gym',
        name: 'BodyLab 月卡',
        categoryId: 'fitness',
        amount: 399,
        cycleDays: 30,
        nextChargeAt: now.add(const Duration(days: 12)),
        channel: PaymentChannel.alipay,
      ),
    ];

    return LedgerBook(
      createdAt: now,
      updatedAt: now,
      entries: entries,
      periods: const [],
      budgets: budgets,
      goals: goals,
      subscriptions: subscriptions,
      assetAccounts: const [],
      customRules: [
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '瑞幸',
          categoryId: 'food',
          autoTags: ['下午茶', '咖啡'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '喜茶',
          categoryId: 'food',
          autoTags: ['下午茶', '奶茶'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '星巴克',
          categoryId: 'food',
          autoTags: ['下午茶', '咖啡'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '美团',
          categoryId: 'food',
          autoTags: ['外卖'],
        ),
        CategorizationRule(
          id: _uuid.v4(),
          pattern: '滴滴',
          categoryId: 'mobility',
          autoTags: ['打车'],
        ),
      ],
      settings: VaultSettings(
        confidentialModeEnabled: confidentialModeEnabled,
        maskAmounts: confidentialModeEnabled,
        quickLockOnBackground: confidentialModeEnabled,
        allowScreenshots: true,
        biometricUnlockEnabled: false,
        autoCaptureEnabled: true,
        defaultExpenseCategoryId: 'daily',
        wechatEnabled: true,
        alipayEnabled: true,
        googlePayEnabled: true,
        taobaoEnabled: true,
        jdEnabled: true,
        pinduoduoEnabled: true,
        xianyuEnabled: true,
        bankEnabled: true,
        voiceInputEnabled: true,
      ),
    );
  }

  final DateTime createdAt;
  final DateTime updatedAt;
  final List<LedgerEntry> entries;
  final List<LedgerPeriod> periods;

  /// 和本地千问的对话记忆（存在加密账本里）。
  final List<LedgerAiMessage> aiMessages;

  /// 上一轮命中的流水，用于"付款方是谁"这类追问。
  final List<String> aiFocusEntryIds;

  /// 商户 → 分类 的缓存（千问第一次判断后写入，之后不再问模型）。
  final Map<String, String> merchantCategories;

  /// 通知骨架 → 模板：学会之后同类通知不用再问模型。
  final Map<String, CaptureTemplate> captureTemplates;

  /// 自动记账走了哪条路：template(模板) / cache(商户缓存) / ai(千问)。
  /// 用来验证"越用越少依赖 AI"。
  final Map<String, int> capturePathStats;

  /// 各 App 的通知延迟画像（来源 → 观察到的最大延迟毫秒）。
  final Map<String, int> captureDelayProfile;

  /// 通知顺序："微信>招商银行" 这类组合出现了几次。
  final Map<String, int> captureSequence;
  final List<BudgetEnvelope> budgets;
  final List<SavingsGoal> goals;
  final List<RecurringPlan> subscriptions;
  final VaultSettings settings;
  final List<AssetAccount> assetAccounts;
  final List<CategorizationRule> customRules;
  final List<FavoriteLocation> favoriteLocations;

  Map<String, dynamic> toJson() => {
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'entries': entries.map((entry) => entry.toJson()).toList(),
    'periods': periods.map((item) => item.toJson()).toList(),
    'aiMessages': aiMessages.map((item) => item.toJson()).toList(),
    'aiFocusEntryIds': aiFocusEntryIds,
    'merchantCategories': merchantCategories,
    'captureTemplates': captureTemplates.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'capturePathStats': capturePathStats,
    'captureDelayProfile': captureDelayProfile,
    'captureSequence': captureSequence,
    'budgets': budgets.map((item) => item.toJson()).toList(),
    'goals': goals.map((item) => item.toJson()).toList(),
    'subscriptions': subscriptions.map((item) => item.toJson()).toList(),
    'settings': settings.toJson(),
    'assetAccounts': assetAccounts.map((e) => e.toJson()).toList(),
    'customRules': customRules.map((e) => e.toJson()).toList(),
    'favoriteLocations': favoriteLocations.map((e) => e.toJson()).toList(),
  };

  factory LedgerBook.fromJson(Map<String, dynamic> json) => LedgerBook(
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    entries: (json['entries'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              LedgerEntry.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    aiMessages: (json['aiMessages'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => LedgerAiMessage.fromJson(Map<String, dynamic>.from(item)))
        .toList(),
    aiFocusEntryIds: (json['aiFocusEntryIds'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(),
    merchantCategories:
        (json['merchantCategories'] as Map<dynamic, dynamic>? ?? const {})
            .map((key, value) => MapEntry('$key', '$value')),
    captureTemplates:
        (json['captureTemplates'] as Map<dynamic, dynamic>? ?? const {}).map(
          (key, value) => MapEntry(
            '$key',
            CaptureTemplate.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
    capturePathStats:
        (json['capturePathStats'] as Map<dynamic, dynamic>? ?? const {}).map(
          (key, value) => MapEntry('$key', (value as num).toInt()),
        ),
    captureDelayProfile:
        (json['captureDelayProfile'] as Map<dynamic, dynamic>? ?? const {}).map(
          (key, value) => MapEntry('$key', (value as num).toInt()),
        ),
    captureSequence:
        (json['captureSequence'] as Map<dynamic, dynamic>? ?? const {}).map(
          (key, value) => MapEntry('$key', (value as num).toInt()),
        ),
    periods: (json['periods'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              LedgerPeriod.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    budgets: (json['budgets'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              BudgetEnvelope.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    goals: (json['goals'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              SavingsGoal.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    subscriptions: (json['subscriptions'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              RecurringPlan.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    settings: VaultSettings.fromJson(
      Map<String, dynamic>.from(json['settings'] as Map? ?? const {}),
    ),
    assetAccounts: (json['assetAccounts'] as List<dynamic>? ?? [])
        .map((e) => AssetAccount.fromJson(e as Map<String, dynamic>))
        .toList(),
    customRules: (json['customRules'] as List<dynamic>? ?? [])
        .map((e) => CategorizationRule.fromJson(e as Map<String, dynamic>))
        .toList(),
    favoriteLocations: (json['favoriteLocations'] as List<dynamic>? ?? [])
        .map((e) => FavoriteLocation.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  LedgerBook copyWith({
    DateTime? createdAt,
    DateTime? updatedAt,
    List<LedgerEntry>? entries,
    List<LedgerPeriod>? periods,
    List<LedgerAiMessage>? aiMessages,
    List<String>? aiFocusEntryIds,
    Map<String, String>? merchantCategories,
    Map<String, CaptureTemplate>? captureTemplates,
    Map<String, int>? capturePathStats,
    Map<String, int>? captureDelayProfile,
    Map<String, int>? captureSequence,
    List<BudgetEnvelope>? budgets,
    List<SavingsGoal>? goals,
    List<RecurringPlan>? subscriptions,
    VaultSettings? settings,
    List<AssetAccount>? assetAccounts,
    List<CategorizationRule>? customRules,
    List<FavoriteLocation>? favoriteLocations,
  }) {
    return LedgerBook(
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      entries: entries ?? this.entries,
      periods: periods ?? this.periods,
      budgets: budgets ?? this.budgets,
      goals: goals ?? this.goals,
      subscriptions: subscriptions ?? this.subscriptions,
      settings: settings ?? this.settings,
      assetAccounts: assetAccounts ?? this.assetAccounts,
      customRules: customRules ?? this.customRules,
      favoriteLocations: favoriteLocations ?? this.favoriteLocations,
      aiMessages: aiMessages ?? this.aiMessages,
      aiFocusEntryIds: aiFocusEntryIds ?? this.aiFocusEntryIds,
      merchantCategories: merchantCategories ?? this.merchantCategories,
      captureTemplates: captureTemplates ?? this.captureTemplates,
      capturePathStats: capturePathStats ?? this.capturePathStats,
      captureDelayProfile: captureDelayProfile ?? this.captureDelayProfile,
      captureSequence: captureSequence ?? this.captureSequence,
    );
  }

  LedgerBook withoutLegacySeedData() {
    final legacySeedBook = LedgerBook.seeded(settings.confidentialModeEnabled);
    final legacyEntryKeys = legacySeedBook.entries.map(_legacyEntryKey).toSet();
    final legacyBudgetKeys = legacySeedBook.budgets
        .map(_legacyBudgetKey)
        .toSet();
    final legacyGoalKeys = legacySeedBook.goals.map(_legacyGoalKey).toSet();
    final legacySubscriptionKeys = legacySeedBook.subscriptions
        .map(_legacySubscriptionKey)
        .toSet();

    final cleanedEntries = entries
        .where((entry) => !legacyEntryKeys.contains(_legacyEntryKey(entry)))
        .toList();
    final cleanedBudgets = budgets
        .where((budget) => !legacyBudgetKeys.contains(_legacyBudgetKey(budget)))
        .toList();
    final cleanedGoals = goals
        .where((goal) => !legacyGoalKeys.contains(_legacyGoalKey(goal)))
        .toList();
    final cleanedSubscriptions = subscriptions
        .where(
          (subscription) => !legacySubscriptionKeys.contains(
            _legacySubscriptionKey(subscription),
          ),
        )
        .toList();

    final changed =
        cleanedEntries.length != entries.length ||
        cleanedBudgets.length != budgets.length ||
        cleanedGoals.length != goals.length ||
        cleanedSubscriptions.length != subscriptions.length;
    if (!changed) {
      return this;
    }

    return copyWith(
      entries: cleanedEntries
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)),
      budgets: cleanedBudgets,
      goals: cleanedGoals,
      subscriptions: cleanedSubscriptions,
      updatedAt: DateTime.now(),
    );
  }

  LedgerBook migrateAutoCapturedUtcTimes() {
    var changed = false;
    final migratedEntries = entries.map((entry) {
      if (!entry.autoCaptured || !entry.occurredAt.isUtc) {
        return entry;
      }
      changed = true;
      final millis = entry.autoPostedAtMillis > 0
          ? entry.autoPostedAtMillis
          : entry.occurredAt.millisecondsSinceEpoch;
      return entry.copyWith(
        occurredAt: DateTime.fromMillisecondsSinceEpoch(millis),
        autoPostedAtMillis: millis,
      );
    }).toList();
    if (!changed) {
      return this;
    }
    return copyWith(
      entries: migratedEntries
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)),
      updatedAt: DateTime.now(),
    );
  }

  LedgerBook backfillAutoCaptureCounterpartyNames() {
    var changed = false;
    final normalizedEntries = entries.map((entry) {
      if (!entry.autoCaptured) {
        return entry;
      }
      final inferredCounterparty = _extractLegacyCounterpartyName(entry);
      final normalizedCounterparty = entry.counterpartyName.trim().isNotEmpty
          ? entry.counterpartyName.trim()
          : inferredCounterparty;
      final normalizedTitle = _normalizedAutoCapturedEntryTitle(
        entry,
        counterpartyName: normalizedCounterparty,
      );
      final normalizedNote = _normalizedAutoCaptureNote(
        detailSummary: entry.note,
        rawBody: entry.note,
        counterpartyName: normalizedCounterparty,
        entryType: entry.type,
      );
      if (normalizedCounterparty == entry.counterpartyName &&
          normalizedTitle == entry.title &&
          normalizedNote == entry.note) {
        return entry;
      }
      changed = true;
      return entry.copyWith(
        counterpartyName: normalizedCounterparty,
        title: normalizedTitle,
        note: normalizedNote,
      );
    }).toList();
    if (!changed) {
      return this;
    }
    return copyWith(
      entries: normalizedEntries
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)),
      updatedAt: DateTime.now(),
    );
  }

  LedgerBook normalizeShoppingAutoCaptureTitles() {
    var changed = false;
    final normalizedEntries = entries.map((entry) {
      final normalizedTitle = normalizedShoppingAutoCaptureTitle(entry);
      if (normalizedTitle == entry.title) {
        return entry;
      }
      changed = true;
      return entry.copyWith(title: normalizedTitle);
    }).toList();
    if (!changed) {
      return this;
    }
    return copyWith(entries: normalizedEntries, updatedAt: DateTime.now());
  }
}

String _legacyEntryKey(LedgerEntry entry) {
  final sortedTags = [...entry.tags]..sort();
  return [
    entry.title.trim(),
    entry.merchant.trim(),
    entry.note.trim(),
    entry.amount.toString(),
    entry.type.name,
    entry.categoryId,
    entry.channel.name,
    ...sortedTags,
  ].join('|');
}

String _legacyBudgetKey(BudgetEnvelope budget) =>
    '${budget.id}|${budget.categoryId}|${budget.monthlyLimit}|${budget.targetLabel.trim()}';

String _legacyGoalKey(SavingsGoal goal) =>
    '${goal.id}|${goal.name.trim()}|${goal.targetAmount}|${goal.currentAmount}|${goal.focusLabel.trim()}';

String _legacySubscriptionKey(RecurringPlan subscription) =>
    '${subscription.id}|${subscription.name.trim()}|${subscription.categoryId}|${subscription.amount}|${subscription.cycleDays}|${subscription.channel.name}';

class AutoCaptureRecord {
  const AutoCaptureRecord({
    required this.id,
    required this.title,
    required this.merchant,
    this.counterpartyName = '',
    required this.rawBody,
    required this.scenario,
    required this.detailSummary,
    required this.amount,
    required this.entryType,
    required this.channel,
    required this.source,
    required this.capturedAt,
    required this.postedAtMillis,
    required this.confidence,
    required this.defaultCategoryId,
    required this.profileId,
    required this.mergeKey,
    required this.relatedSources,
  });

  final String id;
  final String title;
  final String merchant;
  final String counterpartyName;
  final String rawBody;
  final String scenario;
  final String detailSummary;
  final double amount;
  final EntryType entryType;
  final PaymentChannel channel;
  final CaptureSource source;
  final DateTime capturedAt;
  final int postedAtMillis;
  final double confidence;
  final String defaultCategoryId;
  final int profileId;
  final String mergeKey;
  final List<CaptureSource> relatedSources;

  factory AutoCaptureRecord.fromJson(Map<String, dynamic> json) =>
      AutoCaptureRecord(
        id: json['id'] as String,
        title: json['title'] as String,
        merchant: json['merchant'] as String? ?? '未识别商户',
        counterpartyName: json['counterpartyName'] as String? ?? '',
        rawBody: json['rawBody'] as String? ?? '',
        scenario: json['scenario'] as String? ?? '',
        detailSummary: json['detailSummary'] as String? ?? '',
        amount: (json['amount'] as num).toDouble(),
        entryType: EntryType.values.byName(json['entryType'] as String),
        channel: PaymentChannel.values.byName(json['channel'] as String),
        source: CaptureSource.fromNameOrUnknown(json['source'] as String?),
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        postedAtMillis:
            (json['postedAtMillis'] as num?)?.toInt() ??
            DateTime.parse(json['capturedAt'] as String).millisecondsSinceEpoch,
        confidence: (json['confidence'] as num).toDouble(),
        defaultCategoryId: json['defaultCategoryId'] as String? ?? 'daily',
        profileId: (json['profileId'] as num?)?.toInt() ?? -1,
        mergeKey: json['mergeKey'] as String? ?? '',
        relatedSources: (json['relatedSources'] as List<dynamic>? ?? const [])
            .map((item) => CaptureSource.fromNameOrUnknown(item as String?))
            .where((item) => item != CaptureSource.unknown)
            .toList(),
      );
}

double round2(num value) => (value * 100).roundToDouble() / 100;

int _entryEventMillis(LedgerEntry entry) {
  if (entry.autoCaptured && entry.autoPostedAtMillis > 0) {
    return entry.autoPostedAtMillis;
  }
  return entry.occurredAt.millisecondsSinceEpoch;
}

const _familyCounterpartyHints = <String>[
  '妈妈',
  '媽媽',
  '爸爸',
  '爸',
  '老公',
  '老婆',
  '先生',
  '太太',
  '女儿',
  '女兒',
  '儿子',
  '兒子',
  '家人',
  '父亲',
  '父親',
  '母亲',
  '母親',
  '爷爷',
  '奶奶',
  '外婆',
  '外公',
  '室友',
];

bool _containsHint(String lowercase, List<String> hints) =>
    hints.any((hint) => lowercase.contains(hint.toLowerCase()));

/// 解析结果里的“商家：麦当劳”“收款方：李四”这类标签只是说明文字，
/// 匹配分类关键词时要先去掉，否则“家”会命中“商家”，把所有付款都算成家庭。
final _autoCaptureLabelPattern = RegExp(
  r'(商家|店铺|收款方|收款人|付款人|付款方|对方|对象|场景|备注)[:：]',
);

String _autoCaptureMatchText(AutoCaptureRecord capture) => [
  capture.title,
  capture.merchant,
  capture.counterpartyName,
  capture.detailSummary.replaceAll(_autoCaptureLabelPattern, ' '),
  capture.rawBody,
  capture.scenario,
  capture.source.label,
  ...capture.relatedSources.map((item) => item.label),
].join(' ').toLowerCase();

(String, List<String>) inferAutoCaptureCategoryId({
  required LedgerBook book,
  required AutoCaptureRecord capture,
}) {
  final lowercase = _autoCaptureMatchText(capture);
  for (final rule in book.customRules) {
    if (rule.pattern.isNotEmpty &&
        lowercase.contains(rule.pattern.toLowerCase())) {
      return (rule.categoryId, rule.autoTags);
    }
  }
  final categories = categoriesForType(capture.entryType);

  if (capture.entryType == EntryType.expense) {
    if (_containsHint(lowercase, _familyCounterpartyHints)) {
      return ('family', const <String>[]);
    }

    final keywordMatch = categories.firstWhereOrNull(
      (category) =>
          category.id != 'daily' &&
          category.keywords.any(
            (keyword) => lowercase.contains(keyword.toLowerCase()),
          ),
    );
    if (keywordMatch != null) {
      return (keywordMatch.id, const <String>[]);
    }

    if ((capture.source.isShoppingSource ||
            capture.relatedSources.any((item) => item.isShoppingSource)) &&
        _isValidCategoryIdForType('shopping', EntryType.expense)) {
      return ('shopping', const <String>[]);
    }

    if (_isValidCategoryIdForType(
          capture.defaultCategoryId,
          EntryType.expense,
        ) &&
        capture.defaultCategoryId != 'shopping') {
      return (capture.defaultCategoryId, const <String>[]);
    }

    return (resolveDefaultExpenseCategoryId(book.settings), const <String>[]);
  }

  final incomeKeywordMatch = categories.firstWhereOrNull(
    (category) => category.keywords.any(
      (keyword) => lowercase.contains(keyword.toLowerCase()),
    ),
  );
  if (incomeKeywordMatch != null) {
    return (incomeKeywordMatch.id, const <String>[]);
  }
  if (_isValidCategoryIdForType(capture.defaultCategoryId, EntryType.income)) {
    return (capture.defaultCategoryId, const <String>[]);
  }
  return (_fallbackCategoryIdForType(EntryType.income), const <String>[]);
}

String buildAutoCaptureDisplayTitle({
  required CaptureSource source,
  required String scenario,
  required String merchant,
  String counterpartyName = '',
}) {
  final actionLabel = switch (scenario) {
    'codePayment' => '收款码付款',
    'codeReceipt' => '收款码收款',
    'transferPayment' => '转账支出',
    'transferReceipt' => '转账收入',
    'merchantReceipt' => '收款',
    'walletReceipt' => '收款',
    'platformRefund' => '退款',
    'refund' => '退款',
    'receipt' => '收款',
    'platformPayment' => '付款',
    _ => '付款',
  };
  final displayTarget = _preferredDisplayTarget(
    source: source,
    merchant: merchant,
    counterpartyName: counterpartyName,
  );
  if (displayTarget.isEmpty) {
    return '${source.label}$actionLabel';
  }
  return '${source.label}$actionLabel · $displayTarget';
}

String normalizedShoppingAutoCaptureTitle(LedgerEntry entry) {
  if (!entry.autoCaptured) {
    return entry.title;
  }
  final shoppingSource = _shoppingCaptureSourceForEntry(entry);
  if (shoppingSource == CaptureSource.unknown) {
    return entry.title;
  }
  final scenario = entry.type == EntryType.income
      ? 'platformRefund'
      : 'platformPayment';
  return buildAutoCaptureDisplayTitle(
    source: shoppingSource,
    scenario: scenario,
    merchant: entry.merchant,
    counterpartyName: entry.counterpartyName,
  );
}

String buildEntryMetaLine(LedgerEntry entry, {String? periodLabel}) {
  final parts = <String>[
    '类别：${categoryForId(entry.categoryId).name}',
    if (periodLabel != null && periodLabel.trim().isNotEmpty)
      '账期：${periodLabel.trim()}',
    if (entry.counterpartyName.trim().isNotEmpty)
      '${entry.type == EntryType.income ? '付款人' : '收款方'}：${entry.counterpartyName.trim()}',
    if (entry.merchant.trim().isNotEmpty &&
        entry.merchant.trim() != '未识别对象' &&
        entry.merchant.trim() != entry.counterpartyName.trim())
      entry.merchant.trim(),
  ];
  if (entry.autoCaptured && entry.sourceLabel.isNotEmpty) {
    parts.add('来源：${entry.sourceLabel}');
  }
  if (!entry.autoCaptured || entry.channel != PaymentChannel.other) {
    parts.add('渠道：${entry.channel.label}');
  }
  return parts.join(' · ');
}

bool _ledgerPeriodsOverlap(
  DateTime leftStart,
  DateTime leftEnd,
  DateTime rightStart,
  DateTime rightEnd,
) {
  return leftStart.isBefore(rightEnd) && rightStart.isBefore(leftEnd);
}

bool entryFallsWithinPeriod(LedgerEntry entry, LedgerPeriod period) {
  return !entry.occurredAt.isBefore(period.startAt) &&
      entry.occurredAt.isBefore(period.endAt);
}

LedgerPeriod? periodForEntry(LedgerBook book, LedgerEntry entry) {
  return book.periods.firstWhereOrNull(
    (period) => entryFallsWithinPeriod(entry, period),
  );
}

List<LedgerEntry> entriesForPeriod(LedgerBook book, LedgerPeriod period) {
  return book.entries
      .where((entry) => entryFallsWithinPeriod(entry, period))
      .toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
}

String _normalizedAutoCaptureNote({
  required String detailSummary,
  required String rawBody,
  required String counterpartyName,
  required EntryType entryType,
}) {
  final base = detailSummary.trim().isNotEmpty
      ? detailSummary.trim()
      : rawBody.trim();
  if (counterpartyName.trim().isEmpty) {
    return base;
  }
  final roleLabel = entryType == EntryType.income ? '付款人' : '收款方';
  final preferredLine = '$roleLabel：${counterpartyName.trim()}';
  final lines = <String>{
    preferredLine,
    ...base
        .split('\\n')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty),
  };
  lines.removeWhere(
    (line) =>
        (line.startsWith('微信名字：') ||
            line.startsWith('微信名字:') ||
            line.startsWith('支付宝名字：') ||
            line.startsWith('支付宝名字:') ||
            line.startsWith('付款人：') ||
            line.startsWith('付款人:') ||
            line.startsWith('收款方：') ||
            line.startsWith('收款方:')) &&
        line != preferredLine,
  );
  return lines.join('\\n');
}

String _preferredDisplayTarget({
  required CaptureSource source,
  required String merchant,
  required String counterpartyName,
}) {
  final normalizedCounterparty = counterpartyName.trim();
  final normalizedMerchant = merchant.trim();
  if (source.isShoppingSource) {
    return normalizedMerchant == '未识别对象' || normalizedMerchant == '未识别商户'
        ? normalizedCounterparty
        : normalizedMerchant;
  }
  if (normalizedCounterparty.isNotEmpty) {
    return normalizedCounterparty;
  }
  if (normalizedMerchant.isEmpty ||
      normalizedMerchant == '未识别对象' ||
      normalizedMerchant == '未识别商户') {
    return '';
  }
  return normalizedMerchant;
}

String _normalizedAutoCapturedEntryTitle(
  LedgerEntry entry, {
  required String counterpartyName,
}) {
  if (!entry.autoCaptured) {
    return entry.title;
  }
  final explicitSource = CaptureSource.fromLabelOrUnknown(entry.sourceLabel);
  final shoppingSource = _shoppingCaptureSourceForEntry(entry);
  final effectiveSource = explicitSource != CaptureSource.unknown
      ? explicitSource
      : shoppingSource;
  if (effectiveSource == CaptureSource.unknown) {
    return entry.title;
  }
  final scenario = _autoCapturedEntryScenario(entry, effectiveSource);
  return buildAutoCaptureDisplayTitle(
    source: effectiveSource,
    scenario: scenario,
    merchant: entry.merchant,
    counterpartyName: counterpartyName,
  );
}

String _autoCapturedEntryScenario(LedgerEntry entry, CaptureSource source) {
  final joined = '${entry.title} ${entry.note} ${entry.tags.join(' ')}'
      .toLowerCase();
  if (joined.contains('收款码付款')) return 'codePayment';
  if (joined.contains('收款码收款')) return 'codeReceipt';
  if (joined.contains('转账支出')) return 'transferPayment';
  if (joined.contains('转账收入')) return 'transferReceipt';
  if (joined.contains('平台退款')) return 'platformRefund';
  if (joined.contains('平台支付')) return 'platformPayment';
  if (joined.contains('退款')) {
    return source.isShoppingSource ? 'platformRefund' : 'refund';
  }
  if (source.isShoppingSource) {
    return entry.type == EntryType.income
        ? 'platformRefund'
        : 'platformPayment';
  }
  if (source == CaptureSource.googlePay) {
    return entry.type == EntryType.income ? 'walletReceipt' : 'walletPayment';
  }
  return entry.type == EntryType.income ? 'receipt' : 'merchantPayment';
}

String _extractLegacyCounterpartyName(LedgerEntry entry) {
  if (!entry.autoCaptured) {
    return entry.counterpartyName;
  }
  if (entry.counterpartyName.trim().isNotEmpty) {
    return entry.counterpartyName.trim();
  }
  final noteMatch = RegExp(
    r'(?:微信名字|支付宝名字|付款人|收款方)[：:]\s*([^\r\n]+)',
  ).firstMatch(entry.note);
  final noteCandidate = noteMatch?.group(1)?.trim() ?? '';
  if (_looksLikePersonName(noteCandidate)) {
    return noteCandidate;
  }

  final titleParts = entry.title.split('·');
  if (titleParts.length > 1) {
    final titleCandidate = titleParts.last.trim();
    if (_looksLikePersonName(titleCandidate)) {
      return titleCandidate;
    }
  }

  if (_autoEntryLikelyPersonToPerson(entry) &&
      _looksLikePersonName(entry.merchant)) {
    return entry.merchant.trim();
  }
  return '';
}

bool _autoEntryLikelyPersonToPerson(LedgerEntry entry) {
  if (!entry.autoCaptured) {
    return false;
  }
  final joined = '${entry.title} ${entry.note} ${entry.tags.join(' ')}'
      .toLowerCase();
  return joined.contains('转账') ||
      joined.contains('收款码') ||
      joined.contains('付款人') ||
      joined.contains('收款方') ||
      joined.contains('收款');
}

bool _looksLikePersonName(String candidate) {
  final value = candidate.trim();
  if (value.isEmpty || value == '未识别对象' || value == '未识别商户') {
    return false;
  }
  final lower = value.toLowerCase();
  const disallowed = [
    '微信',
    '支付宝',
    'google pay',
    '钱包',
    '淘宝',
    '京东',
    '拼多多',
    '闲鱼',
    '店',
    '店铺',
    '商家',
    '卖家',
    '订单',
    '商城',
    'shop',
    'store',
    'mall',
    '客服',
    '官方',
    '旗舰',
  ];
  if (disallowed.any((item) => lower.contains(item))) {
    return false;
  }
  if (RegExp(r'(?:¥|￥|\$)\s*\d|\d+(?:\.\d+)?\s*(?:元|块|圓|塊)?').hasMatch(value)) {
    return false;
  }
  return true;
}

CaptureSource _shoppingCaptureSourceForEntry(LedgerEntry entry) {
  final shoppingSources = [
    CaptureSource.taobao,
    CaptureSource.jd,
    CaptureSource.pinduoduo,
    CaptureSource.xianyu,
  ];
  for (final source in shoppingSources) {
    if (entry.sourceLabel == source.label ||
        entry.tags.contains(source.label)) {
      return source;
    }
  }
  return CaptureSource.unknown;
}

String formatAmount(
  double amount,
  LedgerViewState state, {
  bool signed = false,
}) {
  final confidential = state.book?.settings.maskAmounts ?? false;
  if (confidential && !state.revealAmounts) {
    return signed ? '¥••••' : '••••';
  }
  final base = _safeCurrencyFormatter.format(amount);
  if (!signed) return base;
  return amount >= 0
      ? '+$base'
      : '-${_safeCurrencyFormatter.format(amount.abs())}';
}

double monthExpenseTotal(LedgerBook book, DateTime anchor) {
  return round2(
    book.entries
        .where(
          (entry) =>
              entry.type == EntryType.expense &&
              entry.occurredAt.year == anchor.year &&
              entry.occurredAt.month == anchor.month,
        )
        .fold<double>(0, (sum, entry) => sum + entry.amount),
  );
}

double monthIncomeTotal(LedgerBook book, DateTime anchor) {
  return round2(
    book.entries
        .where(
          (entry) =>
              entry.type == EntryType.income &&
              entry.occurredAt.year == anchor.year &&
              entry.occurredAt.month == anchor.month,
        )
        .fold<double>(0, (sum, entry) => sum + entry.amount),
  );
}

double monthlySpendForCategory(
  LedgerBook book,
  String categoryId,
  DateTime anchor,
) {
  return round2(
    book.entries
        .where(
          (entry) =>
              entry.categoryId == categoryId &&
              entry.type == EntryType.expense &&
              entry.occurredAt.year == anchor.year &&
              entry.occurredAt.month == anchor.month,
        )
        .fold<double>(0, (sum, entry) => sum + entry.amount),
  );
}

double subscriptionMonthlyLoad(LedgerBook book) {
  return round2(
    book.subscriptions.fold<double>(
      0,
      (sum, item) => sum + (item.amount * (30 / item.cycleDays)),
    ),
  );
}

String monthBalanceLabel(LedgerBook book, LedgerViewState state) {
  final income = monthIncomeTotal(book, DateTime.now());
  final expense = monthExpenseTotal(book, DateTime.now());
  return formatAmount(income - expense, state, signed: true);
}

List<_MonthlyTrendPoint> sixMonthTrend(LedgerBook book) {
  final now = DateTime.now();
  return List.generate(6, (index) {
    final date = DateTime(now.year, now.month - (5 - index), 1);
    return _MonthlyTrendPoint(
      label: _safeMonthFormatter.format(date),
      expense: monthExpenseTotal(book, date),
      income: monthIncomeTotal(book, date),
    );
  });
}

List<_CategorySpend> categorySpends(LedgerBook book) {
  final now = DateTime.now();
  return appCategories
      .where((category) => category.type == EntryType.expense)
      .map(
        (category) => _CategorySpend(
          category: category,
          amount: monthlySpendForCategory(book, category.id, now),
        ),
      )
      .where((item) => item.amount > 0)
      .sortedBy<num>((item) => -item.amount);
}

List<_LifePillarInsight> lifePillarInsights(LedgerBook book) {
  final groups = groupBy(appCategories, (item) => item.pillar);
  return groups.entries
      .map((entry) {
        final categoryIds = entry.value.map((item) => item.id).toSet();
        final spend = book.entries
            .where(
              (item) =>
                  item.type == EntryType.expense &&
                  categoryIds.contains(item.categoryId),
            )
            .fold<double>(0, (sum, item) => sum + item.amount);
        final income = book.entries
            .where(
              (item) =>
                  item.type == EntryType.income &&
                  categoryIds.contains(item.categoryId),
            )
            .fold<double>(0, (sum, item) => sum + item.amount);
        return _LifePillarInsight(
          pillar: entry.key,
          spend: round2(spend),
          income: round2(income),
          activeCategories: book.entries
              .where((item) => categoryIds.contains(item.categoryId))
              .map((item) => categoryForId(item.categoryId).name)
              .toSet()
              .toList(),
        );
      })
      .sortedBy<num>((item) => -item.spend);
}

List<String> smartInsights(LedgerBook book) {
  final now = DateTime.now();
  final expense = monthExpenseTotal(book, now);
  final income = monthIncomeTotal(book, now);
  final foodBudget = book.budgets.firstWhereOrNull(
    (item) => item.categoryId == 'food',
  );
  final foodSpend = monthlySpendForCategory(book, 'food', now);
  final nextCharge = [...book.subscriptions]
    ..sort((a, b) => a.nextChargeAt.compareTo(b.nextChargeAt));
  final autoCount = book.entries.where((entry) => entry.autoCaptured).length;

  return <String>[
    '本月净流入 ${_safeCurrencyFormatter.format(income - expense)}，储蓄率 ${(income == 0 ? 0 : ((income - expense) / income * 100)).clamp(0, 100).round()}%。',
    if (foodBudget != null)
      '餐饮预算已使用 ${(foodSpend / foodBudget.monthlyLimit * 100).clamp(0, 100).round()}%，适合把高频外卖压缩到工作日午间。'
    else
      '餐饮支出是本月最容易被优化的生活面，建议补一个预算信封。',
    if (nextCharge.isNotEmpty)
      '最近一笔固定支出是 ${nextCharge.first.name}，将在 ${_compactDateFormatter.format(nextCharge.first.nextChargeAt)} 扣款。',
    '自动记账累计入账 $autoCount 笔，微信 / 支付宝 / Google Pay 正在做后台通知抓取。',
  ];
}

String _csvCell(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}

String _localFileName(String path) => path.split(Platform.pathSeparator).last;

String _displayLocalPath(String path) => path.replaceAll('\\', '/');

Future<void> _showLocalExportResult(
  BuildContext context, {
  required String directoryPath,
  required List<File> files,
}) async {
  final normalizedPath = _displayLocalPath(directoryPath);
  final visibleFiles = files.map((file) => _localFileName(file.path)).toList();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('已保存到本地'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '导出文件夹',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2C42),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              normalizedPath,
              style: GoogleFonts.plusJakartaSans(
                color: const Color(0xFF60708A),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '已生成文件',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2C42),
              ),
            ),
            const SizedBox(height: 8),
            for (final file in visibleFiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '• $file',
                  style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFF60708A),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: normalizedPath));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(
                  dialogContext,
                ).showSnackBar(const SnackBar(content: Text('导出路径已复制。')));
              }
            },
            child: const Text('复制路径'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

Future<void> _showLocalFileSavedResult(
  BuildContext context, {
  required String filePath,
}) async {
  final normalizedPath = _displayLocalPath(filePath);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('备份已保存'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本地文件',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2C42),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              normalizedPath,
              style: GoogleFonts.plusJakartaSans(
                color: const Color(0xFF60708A),
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: normalizedPath));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(
                  dialogContext,
                ).showSnackBar(const SnackBar(content: Text('备份路径已复制。')));
              }
            },
            child: const Text('复制路径'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

Future<String?> _promptBackupPassword(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String description,
  bool requireConfirmation = false,
}) async {
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var obscurePrimary = true;
        var obscureConfirm = true;
        var errorText = '';
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description,
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePrimary,
                    decoration: InputDecoration(
                      labelText: '备份密码',
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => obscurePrimary = !obscurePrimary),
                        icon: Icon(
                          obscurePrimary
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  if (requireConfirmation) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmController,
                      obscureText: obscureConfirm,
                      decoration: InputDecoration(
                        labelText: '确认备份密码',
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => obscureConfirm = !obscureConfirm),
                          icon: Icon(
                            obscureConfirm
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (errorText.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText,
                      style: GoogleFonts.plusJakartaSans(
                        color: const Color(0xFFC44536),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final password = passwordController.text.trim();
                    final confirmation = confirmController.text.trim();
                    if (password.length < 4) {
                      setState(() => errorText = '备份密码至少 4 位。');
                      return;
                    }
                    if (requireConfirmation && password != confirmation) {
                      setState(() => errorText = '两次输入的备份密码不一致。');
                      return;
                    }
                    Navigator.of(dialogContext).pop(password);
                  },
                  child: Text(confirmLabel),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    passwordController.dispose();
    confirmController.dispose();
  }
}

Future<void> exportLedgerReports(BuildContext context, LedgerBook book) async {
  try {
    final exportDirectoryPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择本地导出文件夹',
      lockParentWindow: true,
    );
    if (exportDirectoryPath == null || exportDirectoryPath.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final exportDir = Directory(exportDirectoryPath);
    await exportDir.create(recursive: true);
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(now);
    final monthLabel = DateFormat('yyyy-MM').format(now);

    final categoryFile = File(
      '${exportDir.path}${Platform.pathSeparator}chaoxi_category_report_$stamp.csv',
    );
    final entriesFile = File(
      '${exportDir.path}${Platform.pathSeparator}chaoxi_entries_$stamp.csv',
    );
    final jsonFile = File(
      '${exportDir.path}${Platform.pathSeparator}chaoxi_snapshot_$stamp.json',
    );

    final categoryRows = <String>[
      'month,category,pillar,expense,budget,usage_rate,transaction_count',
      ...appCategories.where((item) => item.type == EntryType.expense).map((
        category,
      ) {
        final spent = monthlySpendForCategory(book, category.id, now);
        final budget = book.budgets.firstWhereOrNull(
          (item) => item.categoryId == category.id,
        );
        final count = book.entries.where((entry) {
          return entry.categoryId == category.id &&
              entry.type == EntryType.expense &&
              entry.occurredAt.year == now.year &&
              entry.occurredAt.month == now.month;
        }).length;
        final usage = budget == null || budget.monthlyLimit == 0
            ? 0
            : (spent / budget.monthlyLimit * 100);
        return [
          _csvCell(monthLabel),
          _csvCell(category.name),
          _csvCell(category.pillar),
          spent.toStringAsFixed(2),
          (budget?.monthlyLimit ?? 0).toStringAsFixed(2),
          usage.toStringAsFixed(1),
          count.toString(),
        ].join(',');
      }),
    ].join('\\n');

    final entryRows = <String>[
      'date,time,type,category,period_name,title,merchant,counterparty_name,amount,channel,source,tags,auto_captured,note',
      ...book.entries.map((entry) {
        final category = categoryForId(entry.categoryId);
        final period = periodForEntry(book, entry);
        return [
          _csvCell(DateFormat('yyyy-MM-dd').format(entry.occurredAt)),
          _csvCell(DateFormat('HH:mm:ss').format(entry.occurredAt)),
          _csvCell(entry.type.label),
          _csvCell(category.name),
          _csvCell(period?.name ?? ''),
          _csvCell(entry.title),
          _csvCell(entry.merchant),
          _csvCell(entry.counterpartyName),
          entry.amount.toStringAsFixed(2),
          _csvCell(entry.channel.label),
          _csvCell(entry.sourceLabel),
          _csvCell(entry.tags.join('|')),
          _csvCell(entry.autoCaptured ? 'yes' : 'no'),
          _csvCell(entry.note),
        ].join(',');
      }),
    ].join('\\n');

    final jsonPayload = const JsonEncoder.withIndent('  ').convert({
      'exportedAt': now.toIso8601String(),
      'reportMonth': monthLabel,
      'book': book.toJson(),
    });

    await categoryFile.writeAsString(categoryRows, flush: true);
    await entriesFile.writeAsString(entryRows, flush: true);
    await jsonFile.writeAsString(jsonPayload, flush: true);

    if (context.mounted) {
      await _showLocalExportResult(
        context,
        directoryPath: exportDir.path,
        files: [categoryFile, entriesFile, jsonFile],
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }
}

Future<void> exportEncryptedLedgerBackup(
  BuildContext context,
  LedgerBook book,
) async {
  final backupPassword = await _promptBackupPassword(
    context,
    title: '设置导出密码',
    confirmLabel: '保存备份',
    description: '这个密码只用于本次导出的加密备份。以后导入这份备份时，需要输入同一个密码才能解密。',
    requireConfirmation: true,
  );
  if (backupPassword == null || !context.mounted) {
    return;
  }

  try {
    final now = DateTime.now();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(now);
    final payload = const JsonEncoder.withIndent('  ').convert({
      'format': _encryptedBackupFormat,
      'exportedAt': now.toIso8601String(),
      'app': 'chaoxi',
      'cipherText': await const VaultCryptoBridge().encryptLedger(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'book': book.toJson(), 'exportedAt': now.toIso8601String()}),
        backupPassword,
      ),
    });
    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: '选择本地备份文件位置',
      fileName: 'chaoxi_backup_$stamp.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: Uint8List.fromList(utf8.encode(payload)),
      lockParentWindow: true,
    );
    if (outputPath == null || outputPath.isEmpty || !context.mounted) {
      return;
    }
    await _showLocalFileSavedResult(context, filePath: outputPath);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('备份导出失败：$error')));
    }
  }
}

Future<void> pickAndImportLedgerBackup(
  BuildContext context,
  WidgetRef ref,
) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
    dialogTitle: '选择本地加密备份文件',
    lockParentWindow: true,
  );
  final path = result?.files.single.path;
  if (path == null || !context.mounted) {
    return;
  }
  final backupPassword = await _promptBackupPassword(
    context,
    title: '输入导入密码',
    confirmLabel: '继续导入',
    description: '请输入导出这份备份时设置的密码。只有密码正确，才能解密并导入这份本地备份。',
  );
  if (backupPassword == null || !context.mounted) {
    return;
  }
  final confirmed = await _confirmDestructiveAction(
    context,
    title: '导入备份并替换当前账本？',
    message:
        '将从本地加密备份“${_localFileName(path)}”导入，并覆盖当前账本内容；导入成功后，账本仍继续使用你当前的保险库口令重新加密。',
    confirmLabel: '导入替换',
  );
  if (!confirmed || !context.mounted) {
    return;
  }
  await ref
      .read(ledgerControllerProvider.notifier)
      .importEncryptedBackupFromFile(path, backupPassword);
}

bool matchesTransactionQuery(
  LedgerEntry entry,
  String query, {
  LedgerBook? book,
}) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return true;

  final category = categoryForId(entry.categoryId);
  final periodName = book == null
      ? ''
      : (periodForEntry(book, entry)?.name ?? '');
  final haystack = <String>[
    entry.title,
    entry.merchant,
    entry.counterpartyName,
    entry.note,
    entry.locationInfo,
    periodName,
    entry.sourceLabel,
    category.name,
    category.pillar,
    entry.channel.label,
    entry.type.label,
    ...entry.tags,
    entry.amount.toStringAsFixed(2),
  ].join(' ').toLowerCase();

  return haystack.contains(normalized);
}

class _MonthlyTrendPoint {
  const _MonthlyTrendPoint({
    required this.label,
    required this.expense,
    required this.income,
  });

  final String label;
  final double expense;
  final double income;

  double get balance => income - expense;
}

List<LedgerEntry> monthEntriesByType(
  LedgerBook book,
  DateTime anchor,
  EntryType type,
) {
  return book.entries
      .where(
        (entry) =>
            entry.type == type &&
            entry.occurredAt.year == anchor.year &&
            entry.occurredAt.month == anchor.month,
      )
      .toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
}

List<LedgerEntry> monthEntriesForCategory(
  LedgerBook book,
  DateTime anchor,
  String categoryId,
) {
  return book.entries
      .where(
        (entry) =>
            entry.categoryId == categoryId &&
            entry.occurredAt.year == anchor.year &&
            entry.occurredAt.month == anchor.month,
      )
      .toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
}

class _EntryDaySection {
  const _EntryDaySection({required this.day, required this.entries});

  final DateTime day;
  final List<LedgerEntry> entries;
}

List<_EntryDaySection> groupEntriesByDay(List<LedgerEntry> entries) {
  final groups = groupBy(
    entries,
    (LedgerEntry item) => DateTime(
      item.occurredAt.year,
      item.occurredAt.month,
      item.occurredAt.day,
    ),
  );
  final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in days)
      _EntryDaySection(day: day, entries: List<LedgerEntry>.from(groups[day]!)),
  ];
}

class MonthlyEntriesPage extends ConsumerWidget {
  const MonthlyEntriesPage({
    required this.title,
    required this.type,
    required this.anchorMonth,
    super.key,
  });

  final String title;
  final EntryType type;
  final DateTime anchorMonth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(ledgerControllerProvider);
    final book = viewState.book;
    if (book == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('账本暂不可用。')),
      );
    }

    final entries = monthEntriesByType(book, anchorMonth, type);
    final total = entries.fold<double>(0, (sum, item) => sum + item.amount);
    final sections = groupEntriesByDay(entries);

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              sliver: SliverToBoxAdapter(
                child: _AnimatedReveal(
                  child: _GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('yyyy年M月').format(anchorMonth),
                          style: GoogleFonts.plusJakartaSans(
                            color: const Color(0xFF71809A),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          formatAmount(total, viewState),
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '共 ${entries.length} 笔${type.label}流水',
                          style: GoogleFonts.plusJakartaSans(
                            color: const Color(0xFF60708A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
            if (entries.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverToBoxAdapter(
                  child: _AnimatedReveal(
                    child: _EmptyCard(label: '这个月还没有${type.label}记录。'),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final section = sections[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _AnimatedReveal(
                        child: _GlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _safeFullDateFormatter.format(section.day),
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              for (final entry in section.entries)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _EntryTile(
                                    entry: entry,
                                    viewState: viewState,
                                    periodLabel: periodForEntry(
                                      book,
                                      entry,
                                    )?.name,
                                    onTap: () => showEntrySheet(
                                      context,
                                      ref,
                                      initialEntry: entry,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }, childCount: sections.length),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PlansScreenRoute extends ConsumerWidget {
  const PlansScreenRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerControllerProvider);
    final book = state.book;
    return Scaffold(
      appBar: AppBar(title: const Text('计划')),
      body: SafeArea(
        child: book == null
            ? const Center(child: Text('账本暂不可用。'))
            : PlansScreen(book: book, viewState: state),
      ),
    );
  }
}

class _CashFlowChartCard extends StatelessWidget {
  const _CashFlowChartCard({required this.trend, required this.viewState});

  final List<_MonthlyTrendPoint> trend;
  final LedgerViewState viewState;

  @override
  Widget build(BuildContext context) {
    final maxValue = trend.fold<double>(
      0,
      (max, item) => math.max(max, math.max(item.expense, item.income)),
    );
    final chartMax = (maxValue <= 0 ? 1000.0 : (maxValue * 1.25).ceilToDouble())
        .toDouble();
    final interval = (chartMax <= 4000 ? 1000.0 : (chartMax / 4).ceilToDouble())
        .toDouble();

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _LegendDot(color: const Color(0xFF20B57D), label: '收入'),
              const SizedBox(width: 12),
              _LegendDot(color: const Color(0xFF5E83FF), label: '支出'),
              const Spacer(),
              Text(
                '点柱子可看明细',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: const Color(0xFF7A869C),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 240,
            child: RepaintBoundary(
              child: BarChart(
                duration: const Duration(milliseconds: 620),
                curve: Curves.easeOutCubic,
                BarChartData(
                  maxY: chartMax,
                  alignment: BarChartAlignment.spaceAround,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: interval,
                    getDrawingHorizontalLine: (_) =>
                        const FlLine(color: Color(0xFFE7ECF5), strokeWidth: 1),
                  ),
                  barTouchData: BarTouchData(
                    enabled: true,
                    handleBuiltInTouches: true,
                    touchTooltipData: BarTouchTooltipData(
                      tooltipPadding: const EdgeInsets.all(10),
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final point = trend[group.x.toInt()];
                        final lines = [
                          point.label,
                          '收入 ${_safeCurrencyFormatter.format(point.income)}',
                          '支出 ${_safeCurrencyFormatter.format(point.expense)}',
                          '净结余 ${_safeCurrencyFormatter.format(point.balance)}',
                        ];
                        return BarTooltipItem(
                          lines.join('\\n'),
                          GoogleFonts.plusJakartaSans(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 42,
                        interval: interval,
                        getTitlesWidget: (value, meta) => Text(
                          value == 0 ? '0' : '${(value / 1000).round()}k',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            color: const Color(0xFF74839B),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= trend.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              trend[index].label,
                              style: GoogleFonts.plusJakartaSans(fontSize: 11),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: [
                    for (var i = 0; i < trend.length; i++)
                      BarChartGroupData(
                        x: i,
                        barsSpace: 6,
                        barRods: [
                          BarChartRodData(
                            toY: trend[i].expense,
                            color: const Color(0xFF5E83FF),
                            width: 12,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          BarChartRodData(
                            toY: trend[i].income,
                            color: const Color(0xFF20B57D),
                            width: 12,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final point in trend)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: point.balance >= 0
                            ? const Color(0xFFE8F7F0)
                            : const Color(0xFFF3F6FC),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${point.label} ${formatAmount(point.balance, viewState, signed: true)}',
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700,
                          color: point.balance >= 0
                              ? const Color(0xFF0E9360)
                              : const Color(0xFF4E6079),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w600,
            color: const Color(0xFF60708A),
          ),
        ),
      ],
    );
  }
}

class _CategorySpend {
  const _CategorySpend({required this.category, required this.amount});

  final AppCategory category;
  final double amount;
}

class _LifePillarInsight {
  const _LifePillarInsight({
    required this.pillar,
    required this.spend,
    required this.income,
    required this.activeCategories,
  });

  final String pillar;
  final double spend;
  final double income;
  final List<String> activeCategories;
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _AmbientBackgroundPainter(progress: 0.5),
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}

class _AmbientBackgroundPainter extends CustomPainter {
  const _AmbientBackgroundPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;

    _paintOrb(
      canvas,
      center: Offset(width * 0.88 - 14 * progress, 86 + 18 * progress),
      radius: 168 + 10 * progress,
      colors: const [Color(0x403F86FF), Color(0x06FFFFFF)],
    );
    _paintOrb(
      canvas,
      center: Offset(-12 + 24 * progress, 248 - 16 * progress),
      radius: 150 + 6 * (1 - progress),
      colors: const [Color(0x28FFC56E), Color(0x00FFFFFF)],
    );
    _paintOrb(
      canvas,
      center: Offset(width - 24 + 12 * progress, height - 74 + 10 * progress),
      radius: 182 + 8 * progress,
      colors: const [Color(0x1E41D8C6), Color(0x00FFFFFF)],
    );
  }

  void _paintOrb(
    Canvas canvas, {
    required Offset center,
    required double radius,
    required List<Color> colors,
  }) {
    final paint = Paint()
      ..shader = ui.Gradient.radial(center, radius, colors, const [0, 1]);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _AmbientBackgroundPainter oldDelegate) {
    return false;
  }
}

class _TopBanner extends StatelessWidget {
  const _TopBanner({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withValues(alpha: 0.22)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E6CF7), Color(0xFF6A7BFF)],
                ),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.wallet_rounded,
                color: Colors.white,
                size: 42,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '潮汐账本',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '自动记账、预算、目标和机密模式正在准备中',
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(
                color: const Color(0xFF5F6E87),
              ),
            ),
            const SizedBox(height: 22),
            const CircularProgressIndicator(strokeWidth: 2.4),
          ],
        ),
      ),
    );
  }
}

class _AnimatedReveal extends StatefulWidget {
  const _AnimatedReveal({required this.child});

  final Widget child;

  @override
  State<_AnimatedReveal> createState() => _AnimatedRevealState();
}

class _AnimatedRevealState extends State<_AnimatedReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(curve);
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.022),
      end: Offset.zero,
    ).animate(curve);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}

class _TouchableScale extends StatefulWidget {
  const _TouchableScale({
    required this.child,
    this.onTap,
    required this.borderRadius,
    this.pressScale = 0.985,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final double pressScale;

  @override
  State<_TouchableScale> createState() => _TouchableScaleState();
}

class _TouchableScaleState extends State<_TouchableScale> {
  var _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || widget.onTap == null) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? widget.pressScale : 1,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      child: InkWell(
        onTap: widget.onTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        borderRadius: widget.borderRadius,
        child: widget.child,
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _AnimatedReveal(
      // 每张卡都带模糊阴影，加一层重绘边界后滚动时不用反复重新栅格化。
      child: RepaintBoundary(
        child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.9),
              const Color(0xFFF8FBFF).withValues(alpha: 0.84),
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
          boxShadow: [
            BoxShadow(
              color: const Color(0x120E1A33).withValues(alpha: 0.12),
              blurRadius: 30,
              offset: const Offset(0, 18),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.32),
              blurRadius: 0,
              spreadRadius: 1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.all(18),
        child: child,
        ),
      ),
    );
  }
}

class _FeatureBullet extends StatelessWidget {
  const _FeatureBullet(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(
              Icons.check_circle_outline,
              size: 18,
              color: Color(0xFF1E6CF7),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: GoogleFonts.plusJakartaSans(height: 1.5)),
          ),
        ],
      ),
    );
  }
}

class _BottomDockBar extends StatelessWidget {
  const _BottomDockBar({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _items = [
    _DockItemData(
      label: '总览',
      icon: Icons.dashboard_customize_outlined,
      activeIcon: Icons.dashboard_customize,
    ),
    _DockItemData(
      label: '流水',
      icon: Icons.receipt_long_outlined,
      activeIcon: Icons.receipt_long,
    ),
    _DockItemData(
      label: '计划',
      icon: Icons.tune_outlined,
      activeIcon: Icons.tune,
    ),
    _DockItemData(
      label: '洞察',
      icon: Icons.auto_graph_outlined,
      activeIcon: Icons.auto_graph,
    ),
    _DockItemData(
      label: '机密',
      icon: Icons.lock_outline,
      activeIcon: Icons.lock,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final itemWidth = math.min(
      (MediaQuery.sizeOf(context).width - 42) / _items.length,
      72.0,
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          10,
          0,
          10,
          math.max(8, bottomInset * 0.28),
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          widthFactor: 1,
          heightFactor: 1,
          child: RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.96),
                    const Color(0xFFF3F8FF).withValues(alpha: 0.9),
                  ],
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white.withValues(alpha: 0.84)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x120E1A33),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _items.length; i++)
                    SizedBox(
                      width: itemWidth,
                      child: _BottomDockItem(
                        data: _items[i],
                        selected: selectedIndex == i,
                        onTap: () => onSelected(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItemData {
  const _DockItemData({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

class _BottomDockItem extends StatelessWidget {
  const _BottomDockItem({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  final _DockItemData data;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final activeText = const Color(0xFF143A73);
    final inactiveText = const Color(0xFF6F7F96);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFDFEFF), Color(0xFFEAF2FF)],
                  )
                : null,
            border: Border.all(
              color: selected ? const Color(0xFFDBE7FB) : Colors.transparent,
            ),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x18345EA8),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSlide(
                duration: const Duration(milliseconds: 360),
                curve: Curves.easeOutCubic,
                offset: selected ? Offset.zero : const Offset(0, 0.06),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutBack,
                  scale: selected ? 1.08 : 1,
                  child: Icon(
                    selected ? data.activeIcon : data.icon,
                    size: 22,
                    color: selected ? activeText : inactiveText,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? activeText : inactiveText,
                  letterSpacing: 0.1,
                ),
                child: Text(data.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onTap,
  });

  final String title;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        if (actionLabel.isNotEmpty && onTap != null)
          TextButton(onPressed: onTap, child: Text(actionLabel)),
      ],
    );
  }
}

class _VaultSetupScreen extends ConsumerStatefulWidget {
  const _VaultSetupScreen();

  @override
  ConsumerState<_VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends ConsumerState<_VaultSetupScreen> {
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _confidentialModeEnabled = true;
  bool _obscure = true;

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(ledgerControllerProvider.notifier);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 24 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '把生活账本先锁起来',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 32,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '潮汐账本会把你的账本整体加密保存。机密模式启用后，金额默认打码，回到后台会自动锁定，并使用标准 AES-GCM 加密在 Android 本地落盘。',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 15,
              height: 1.6,
              color: const Color(0xFF5F6E87),
            ),
          ),
          const SizedBox(height: 24),
          _GlassCard(
            child: Column(
              children: [
                TextField(
                  controller: _passphraseController,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: '设置保险库口令',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _confirmController,
                  obscureText: _obscure,
                  decoration: const InputDecoration(labelText: '再次确认口令'),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('默认开启机密模式'),
                  subtitle: const Text('金额打码、后台自动锁定、适合日常通勤场景'),
                  value: _confidentialModeEnabled,
                  onChanged: (value) =>
                      setState(() => _confidentialModeEnabled = value),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      if (_passphraseController.text !=
                          _confirmController.text) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('两次输入的口令不一致。')),
                        );
                        return;
                      }
                      controller.createVault(
                        passphrase: _passphraseController.text,
                        confidentialModeEnabled: _confidentialModeEnabled,
                      );
                    },
                    child: const Text('创建加密账本'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _FeatureBullet('总览：看收入、支出、储蓄率、订阅压力与生活维度覆盖度。'),
                _FeatureBullet('流水：支持手动记账、筛选、自动记账导入和来源回溯。'),
                _FeatureBullet('计划：预算、目标、固定支出、应急金与旅行计划都能落地。'),
                _FeatureBullet(
                  '机密：微信、支付宝、Google Pay 通知自动记账和标准 AES-GCM 本地加密落盘。',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VaultUnlockScreen extends ConsumerStatefulWidget {
  const _VaultUnlockScreen();

  @override
  ConsumerState<_VaultUnlockScreen> createState() => _VaultUnlockScreenState();
}

class _VaultUnlockScreenState extends ConsumerState<_VaultUnlockScreen> {
  final _passphraseController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerControllerProvider);
    final controller = ref.read(ledgerControllerProvider.notifier);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 74,
                      height: 74,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1E6CF7), Color(0xFF7B6FFF)],
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(
                        Icons.lock_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      '保险库已锁定',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '输入你的机密口令，继续管理生活账本与自动记账。',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        color: const Color(0xFF5F6E87),
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _passphraseController,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: '机密口令',
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility,
                          ),
                        ),
                      ),
                      onSubmitted: (_) {
                        FocusScope.of(context).unfocus();
                        controller.unlockVault(_passphraseController.text);
                      },
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: state.busy
                            ? null
                            : () {
                                FocusScope.of(context).unfocus();
                                controller.unlockVault(
                                  _passphraseController.text,
                                );
                              },
                        child: Text(state.busy ? '正在解锁...' : '解锁账本'),
                      ),
                    ),
                    if (state.biometricAvailable) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: state.busy
                              ? null
                              : () {
                                  FocusScope.of(context).unfocus();
                                  controller.unlockWithBiometric();
                                },
                          icon: const Icon(Icons.fingerprint_rounded),
                          label: Text(state.busy ? '正在校验指纹...' : '指纹解锁'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '先手动口令解锁一次，并在机密页开启指纹解锁，之后就可以直接用指纹进入账本。',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.plusJakartaSans(
                          color: const Color(0xFF73809A),
                          height: 1.45,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => _confirmReset(context, controller),
                      child: const Text(
                        '忘记口令？重置账本',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (state.errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          state.errorMessage!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _confirmReset(BuildContext context, LedgerController controller) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置账本'),
        content: const Text(
          '警告：此操作将永久删除所有账本数据，包括所有流水记录、预算\n和设置。删除后无法恢复。\n\n确定要重置吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(ctx);
              controller.resetVault();
            },
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
  }
}

/// 金额滚动：数字变化时从旧值滑到新值，一次性动画，不循环。
class _RollingAmountText extends StatelessWidget {
  const _RollingAmountText({
    required this.value,
    required this.fallbackText,
    required this.formatter,
    required this.style,
  });

  final double value;
  final String fallbackText;
  final String Function(double value) formatter;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: const Duration(milliseconds: 720),
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) => Text(formatter(animated), style: style),
    );
  }
}

class _HeroLedgerCard extends StatelessWidget {
  const _HeroLedgerCard({
    required this.title,
    required this.subtitle,
    required this.amountText,
    required this.chips,
    required this.trailing,
    this.amountValue,
    this.amountFormatter,
    this.animateAmount = false,
  });

  final String title;
  final String subtitle;
  final String amountText;
  final List<_HeroChipAction> chips;
  final Widget trailing;

  /// 金额的数值形式；给了就在数字变化时做滚动动画。
  final double? amountValue;
  final String Function(double value)? amountFormatter;
  final bool animateAmount;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF12254C), Color(0xFF2B4A8E), Color(0xFF8057FF)],
        ),
        borderRadius: BorderRadius.circular(32),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.plusJakartaSans(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (animateAmount &&
                        amountValue != null &&
                        amountFormatter != null)
                      _RollingAmountText(
                        value: amountValue!,
                        fallbackText: amountText,
                        formatter: amountFormatter!,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      )
                    else
                      Text(
                        amountText,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: GoogleFonts.plusJakartaSans(
                        color: Colors.white.withValues(alpha: 0.75),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              trailing,
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips
                .map(
                  (chip) => InkWell(
                    onTap: chip.onTap,
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(
                          alpha: chip.onTap == null ? 0.12 : 0.18,
                        ),
                        borderRadius: BorderRadius.circular(999),
                        border: chip.onTap == null
                            ? null
                            : Border.all(
                                color: Colors.white.withValues(alpha: 0.24),
                              ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            chip.label,
                            style: GoogleFonts.plusJakartaSans(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (chip.onTap != null) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _HeroChipAction {
  const _HeroChipAction({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.detail,
    required this.accent,
  });

  final String label;
  final String value;
  final String detail;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.bolt_rounded, color: accent),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              color: const Color(0xFF6A7790),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: GoogleFonts.plusJakartaSans(color: const Color(0xFF7D899E)),
          ),
        ],
      ),
    );
  }
}

class _QuickActionChip extends StatelessWidget {
  const _QuickActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _TouchableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      pressScale: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F143A73),
              blurRadius: 16,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF2E4A86)),
            const SizedBox(width: 10),
            Text(
              label,
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategorySpendTile extends StatelessWidget {
  const _CategorySpendTile({
    required this.category,
    required this.amount,
    required this.state,
  });

  final AppCategory category;
  final double amount;
  final LedgerViewState state;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: category.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(category.icon, color: category.color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.name,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  category.pillar,
                  style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFF71809A),
                  ),
                ),
              ],
            ),
          ),
          Text(
            formatAmount(amount, state),
            style: GoogleFonts.spaceGrotesk(
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.viewState,
    this.onTap,
    this.periodLabel,
  });

  final LedgerEntry entry;
  final LedgerViewState viewState;
  final VoidCallback? onTap;
  final String? periodLabel;

  @override
  Widget build(BuildContext context) {
    final category = categoryForId(entry.categoryId);
    final signedAmount = entry.type == EntryType.expense
        ? -entry.amount
        : entry.amount;
    return _TouchableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: const Color(0xFFF6F8FD),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(
              color: Color(0x081B2436),
              blurRadius: 12,
              offset: Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(category.icon, color: category.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    buildEntryMetaLine(entry, periodLabel: periodLabel),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: const Color(0xFF7A869C),
                    ),
                  ),
                  if (entry.note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      entry.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        color: const Color(0xFF7A869C),
                      ),
                    ),
                  ],
                  if (entry.tags.isNotEmpty ||
                      entry.linkedRefundEntryIds.isNotEmpty ||
                      entry.locationInfo.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (entry.locationInfo.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8EAF6),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.location_on,
                                  size: 11,
                                  color: Color(0xFF5C6BC0),
                                ),
                                const SizedBox(width: 2),
                                Flexible(
                                  child: Text(
                                    entry.locationInfo,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF5C6BC0),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (entry.linkedRefundEntryIds.isNotEmpty &&
                            viewState.book != null)
                          Builder(
                            builder: (context) {
                              final refundAmount = entry.linkedRefundEntryIds
                                  .map(
                                    (id) =>
                                        viewState.book!.entries
                                            .where((e) => e.id == id)
                                            .firstOrNull
                                            ?.amount ??
                                        0.0,
                                  )
                                  .fold<double>(0.0, (a, b) => a + b);
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEBF8EE),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '已关联退款 +￥${refundAmount.toStringAsFixed(2)}',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF11A66A),
                                  ),
                                ),
                              );
                            },
                          ),
                        ...entry.tags
                            .take(3)
                            .map(
                              (tag) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE9EEF8),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  tag,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF53627B),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatAmount(signedAmount, viewState, signed: true),
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: signedAmount >= 0
                        ? const Color(0xFF11A66A)
                        : const Color(0xFF1B2436),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('HH:mm').format(entry.occurredAt),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    color: const Color(0xFF7A869C),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.plan, required this.state, this.onTap});

  final RecurringPlan plan;
  final LedgerViewState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final category = categoryForId(plan.categoryId);
    final daysLeft = plan.nextChargeAt.difference(DateTime.now()).inDays;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: _GlassCard(
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(category.icon, color: category.color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plan.name,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${plan.channel.label} · ${daysLeft < 0 ? '待扣款' : '$daysLeft 天后扣款'}',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF71809A),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatAmount(plan.amount, state),
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(height: 4),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF7A869C),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodTile extends StatelessWidget {
  const _PeriodTile({
    required this.period,
    required this.state,
    required this.entryCount,
    this.onTap,
  });

  final LedgerPeriod period;
  final LedgerViewState state;
  final int entryCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final days = period.endAt.difference(period.startAt).inDays;
    return _TouchableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: _GlassCard(
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFF1867D8).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.schedule_rounded,
                color: Color(0xFF1867D8),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    period.name,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_compactDateFormatter.format(period.startAt)} - ${_compactDateFormatter.format(period.endAt)}',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF71809A),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$days 天',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$entryCount 笔流水',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    color: const Color(0xFF7A869C),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.plusJakartaSans(
            color: const Color(0xFF74839B),
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({
    required this.book,
    required this.viewState,
    super.key,
  });

  final LedgerBook book;
  final LedgerViewState viewState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final monthIncome = monthIncomeTotal(book, now);
    final monthExpense = monthExpenseTotal(book, now);
    final trend = sixMonthTrend(book);
    final topCategories = categorySpends(book).take(4).toList();
    final upcomingPlans = [...book.subscriptions]
      ..sort((a, b) => a.nextChargeAt.compareTo(b.nextChargeAt));

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
          sliver: SliverList.list(
            children: [
              Text(
                '欢迎回来，今天把生活和现金流看清楚',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 29,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '你的账本已经覆盖日常消费、成长、家庭、宠物、订阅和收入结构。',
                style: GoogleFonts.plusJakartaSans(
                  color: const Color(0xFF60708A),
                ),
              ),
              const SizedBox(height: 20),
              _AnimatedReveal(
                child: _HeroLedgerCard(
                  title: '本月净结余',
                  subtitle: '自动记账与手动记账实时汇总',
                  amountText: monthBalanceLabel(book, viewState),
                  // 打码时不滚动，避免把隐藏的金额用动画"漏"出来。
                  amountValue:
                      monthIncomeTotal(book, DateTime.now()) -
                      monthExpenseTotal(book, DateTime.now()),
                  amountFormatter: (value) =>
                      formatAmount(value, viewState, signed: true),
                  animateAmount:
                      !book.settings.maskAmounts || viewState.revealAmounts,
                  chips: [
                    _HeroChipAction(
                      label: '收入 ${formatAmount(monthIncome, viewState)}',
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: MonthlyEntriesPage(
                            title: '本月收入',
                            type: EntryType.income,
                            anchorMonth: now,
                          ),
                        );
                      },
                    ),
                    _HeroChipAction(
                      label: '支出 ${formatAmount(monthExpense, viewState)}',
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: MonthlyEntriesPage(
                            title: '本月支出',
                            type: EntryType.expense,
                            anchorMonth: now,
                          ),
                        );
                      },
                    ),
                    _HeroChipAction(
                      label:
                          '订阅月压 ${formatAmount(subscriptionMonthlyLoad(book), viewState)}',
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: const PlansScreenRoute(),
                        );
                      },
                    ),
                  ],
                  trailing: IconButton.filledTonal(
                    onPressed: () {
                      ref
                          .read(ledgerControllerProvider.notifier)
                          .revealAmounts(!viewState.revealAmounts);
                    },
                    icon: Icon(
                      viewState.revealAmounts
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _AnimatedReveal(
                child: Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        label: '生活覆盖',
                        value:
                            '${lifePillarInsights(book).where((item) => item.spend > 0 || item.income > 0).length} 个面向',
                        detail: '预算、目标、自动记账一起跟进',
                        accent: const Color(0xFF3A7CFF),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: '自动记账',
                        value:
                            '${book.entries.where((entry) => entry.autoCaptured).length} 笔',
                        detail: viewState.notificationAccessGranted
                            ? '通知监听已开启'
                            : '待授权通知读取',
                        accent: const Color(0xFF11A66A),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SectionHeader(
                title: '快捷动作',
                actionLabel: '全部同步',
                onTap: () {
                  ref
                      .read(ledgerControllerProvider.notifier)
                      .syncAutoCapturedEntries();
                },
              ),
              const SizedBox(height: 12),
              _AnimatedReveal(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _QuickActionChip(
                      icon: Icons.add_card_rounded,
                      label: '记支出',
                      onTap: () => showEntrySheet(context, ref),
                    ),
                    _QuickActionChip(
                      icon: Icons.arrow_downward_rounded,
                      label: '记收入',
                      onTap: () => showEntrySheet(
                        context,
                        ref,
                        forcedType: EntryType.income,
                      ),
                    ),
                    _QuickActionChip(
                      icon: Icons.tune_rounded,
                      label: '设预算',
                      onTap: () => showBudgetSheet(context, ref),
                    ),
                    _QuickActionChip(
                      icon: Icons.flag_rounded,
                      label: '新目标',
                      onTap: () => showGoalSheet(context, ref),
                    ),
                    _QuickActionChip(
                      icon: Icons.calendar_month_rounded,
                      label: '订阅计划',
                      onTap: () => showSubscriptionSheet(context, ref),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _SectionHeader(
                title: '目前我的资产',
                actionLabel: '管理',
                onTap: () => pushPremiumPage<void>(
                  context,
                  page: AssetAccountsView(book: book),
                ),
              ),
              const SizedBox(height: 12),
              AssetAccountsCard(book: book, viewState: viewState),
              const SizedBox(height: 12),
              SubscriptionRadarCard(book: book),
              BurnRatePredictorCard(book: book),
              const SizedBox(height: 22),
              _SectionHeader(title: '近六个月现金流', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              _CashFlowChartCard(trend: trend, viewState: viewState),
              const SizedBox(height: 22),
              _SectionHeader(title: '本月重点生活面', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              for (final item in topCategories)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _CategorySpendTile(
                    category: item.category,
                    amount: item.amount,
                    state: viewState,
                  ),
                ),
              const SizedBox(height: 22),
              _SectionHeader(title: '即将发生的固定支出', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              if (upcomingPlans.isEmpty)
                const _EmptyCard(label: '还没有固定支出，适合把会员、宽带或健身卡补进来。')
              else
                for (final plan in upcomingPlans.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PlanTile(
                      plan: plan,
                      state: viewState,
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: SubscriptionDetailPage(planId: plan.id),
                        );
                      },
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({
    required this.book,
    required this.viewState,
    super.key,
  });

  final LedgerBook book;
  final LedgerViewState viewState;

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  String _mode = 'all';
  String _periodId = 'all';
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  Future<bool> _confirmDelete(BuildContext context, LedgerEntry entry) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除这笔流水？'),
            content: Text('将删除“${entry.title}”，这个操作不会恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activePeriodId =
        widget.book.periods.any((item) => item.id == _periodId)
        ? _periodId
        : 'all';
    final entries = widget.book.entries.where((entry) {
      final modeMatched = switch (_mode) {
        'expense' => entry.type == EntryType.expense,
        'income' => entry.type == EntryType.income,
        'auto' => entry.autoCaptured,
        'wechat' => entry.sourceLabel == CaptureSource.wechat.label,
        'alipay' => entry.sourceLabel == CaptureSource.alipay.label,
        'google' => entry.sourceLabel == CaptureSource.googlePay.label,
        'taobao' =>
          entry.sourceLabel == CaptureSource.taobao.label ||
              entry.tags.contains(CaptureSource.taobao.label),
        'jd' =>
          entry.sourceLabel == CaptureSource.jd.label ||
              entry.tags.contains(CaptureSource.jd.label),
        'pinduoduo' =>
          entry.sourceLabel == CaptureSource.pinduoduo.label ||
              entry.tags.contains(CaptureSource.pinduoduo.label),
        'xianyu' =>
          entry.sourceLabel == CaptureSource.xianyu.label ||
              entry.tags.contains(CaptureSource.xianyu.label),
        'location' => entry.locationInfo.isNotEmpty,
        _ => true,
      };
      final periodMatched =
          activePeriodId == 'all' ||
          widget.book.periods.any(
            (period) =>
                period.id == activePeriodId &&
                entryFallsWithinPeriod(entry, period),
          );
      return modeMatched &&
          periodMatched &&
          matchesTransactionQuery(entry, _query, book: widget.book);
    }).toList()..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final groups = groupBy(
      entries,
      (LedgerEntry item) => DateTime(
        item.occurredAt.year,
        item.occurredAt.month,
        item.occurredAt.day,
      ),
    );

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
          sliver: SliverList.list(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '所有流水都能追到来源',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => showEntrySheet(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('记一笔'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: '搜索标题、商户、账期、备注、金额、标签、位置或渠道',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    _query.isEmpty
                        ? '已展示 ${entries.length} 笔流水'
                        : '搜索结果 ${entries.length} 笔',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (_query.isNotEmpty)
                    Text(
                      '关键词: $_query',
                      style: GoogleFonts.plusJakartaSans(
                        color: const Color(0xFF7A869C),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final item in const [
                      ('all', '全部'),
                      ('expense', '支出'),
                      ('income', '收入'),
                      ('auto', '自动导入'),
                      ('wechat', '微信'),
                      ('alipay', '支付宝'),
                      ('google', 'Google Pay'),
                      ('taobao', '淘宝'),
                      ('jd', '京东'),
                      ('pinduoduo', '拼多多'),
                      ('xianyu', '闲鱼'),
                      ('location', '📍 有位置'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(item.$2),
                          selected: _mode == item.$1,
                          onSelected: (_) => setState(() => _mode = item.$1),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.book.periods.isNotEmpty) ...[
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: const Text('全部账期'),
                          selected: activePeriodId == 'all',
                          onSelected: (_) => setState(() => _periodId = 'all'),
                        ),
                      ),
                      for (final period in widget.book.periods)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(period.name),
                            selected: activePeriodId == period.id,
                            onSelected: (_) =>
                                setState(() => _periodId = period.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (entries.isEmpty)
                _EmptyCard(
                  label: _query.isNotEmpty
                      ? '没有匹配 "$_query" 的流水，试试商户名、金额或标签。'
                      : '这个筛选条件下还没有流水，切个维度看看。',
                )
              else
                for (final entry in groups.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _AnimatedReveal(
                      child: _GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _safeFullDateFormatter.format(entry.key),
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (final item in entry.value)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Dismissible(
                                  key: ValueKey(item.id),
                                  direction: DismissDirection.endToStart,
                                  background: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFC44536),
                                      borderRadius: BorderRadius.circular(22),
                                    ),
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: const Icon(
                                      Icons.delete_outline_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                  confirmDismiss: (_) =>
                                      _confirmDelete(context, item),
                                  onDismissed: (_) {
                                    ref
                                        .read(ledgerControllerProvider.notifier)
                                        .deleteEntry(item.id);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('已删除“${item.title}”'),
                                      ),
                                    );
                                  },
                                  child: _EntryTile(
                                    entry: item,
                                    viewState: widget.viewState,
                                    periodLabel: periodForEntry(
                                      widget.book,
                                      item,
                                    )?.name,
                                    onTap: () => showEntrySheet(
                                      context,
                                      ref,
                                      initialEntry: item,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BudgetTile extends StatelessWidget {
  const _BudgetTile({
    required this.budget,
    required this.spentAmount,
    required this.viewState,
    this.onTap,
  });

  final BudgetEnvelope budget;
  final double spentAmount;
  final LedgerViewState viewState;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final category = categoryForId(budget.categoryId);
    final progress = budget.monthlyLimit == 0
        ? 0
        : spentAmount / budget.monthlyLimit;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: _GlassCard(
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: category.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(category.icon, color: category.color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.name,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        budget.targetLabel,
                        style: GoogleFonts.plusJakartaSans(
                          color: const Color(0xFF73809A),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${formatAmount(spentAmount, viewState)} / ${formatAmount(budget.monthlyLimit, viewState)}',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (onTap != null) ...[
                      const SizedBox(height: 4),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Color(0xFF7A869C),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: progress.clamp(0, 1).toDouble(),
                backgroundColor: const Color(0xFFE8ECF4),
                valueColor: AlwaysStoppedAnimation(
                  progress > 1 ? const Color(0xFFC44536) : category.color,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                progress > 1
                    ? '已超预算 ${formatAmount(spentAmount - budget.monthlyLimit, viewState)}'
                    : '还剩 ${formatAmount(budget.monthlyLimit - spentAmount, viewState)}',
                style: GoogleFonts.plusJakartaSans(
                  color: progress > 1
                      ? const Color(0xFFC44536)
                      : const Color(0xFF73809A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({required this.goal, required this.state, this.onTap});

  final SavingsGoal goal;
  final LedgerViewState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: _GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        goal.name,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${goal.focusLabel} · 截止 ${_compactDateFormatter.format(goal.dueDate)}',
                        style: GoogleFonts.plusJakartaSans(
                          color: const Color(0xFF71809A),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${(goal.progress * 100).round()}%',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (onTap != null) ...[
                      const SizedBox(height: 4),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Color(0xFF7A869C),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 12,
                value: goal.progress,
                backgroundColor: const Color(0xFFE8ECF4),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF1E6CF7)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${formatAmount(goal.currentAmount, state)} / ${formatAmount(goal.targetAmount, state)}',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightBulletCard extends StatelessWidget {
  const _InsightBulletCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFE3EEFF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.lightbulb_outline_rounded,
              color: Color(0xFF1E6CF7),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.plusJakartaSans(fontSize: 15, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _PillarTile extends StatelessWidget {
  const _PillarTile({required this.pillar, required this.state});

  final _LifePillarInsight pillar;
  final LedgerViewState state;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                pillar.pillar,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '支出 ${formatAmount(pillar.spend, state)}',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            pillar.activeCategories.isEmpty
                ? '目前还没有这个面向的账本记录'
                : pillar.activeCategories.join(' · '),
            style: GoogleFonts.plusJakartaSans(color: const Color(0xFF71809A)),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: (pillar.spend / math.max(1, pillar.spend + pillar.income))
                  .clamp(0, 1),
              backgroundColor: const Color(0xFFE8ECF4),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF5E83FF)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.value,
    required this.accent,
  });

  final String title;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            value,
            style: GoogleFonts.plusJakartaSans(
              color: accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceSwitchTile extends StatelessWidget {
  const _SourceSwitchTile({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}

class PlansScreen extends ConsumerWidget {
  const PlansScreen({required this.book, required this.viewState, super.key});

  final LedgerBook book;
  final LedgerViewState viewState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
          sliver: SliverList.list(
            children: [
              Text(
                '预算、目标、账期和固定计划都在这里',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '别只看账单发生了什么，也要提前安排接下来要花在哪里，或者属于哪段生活阶段。',
                style: GoogleFonts.plusJakartaSans(
                  color: const Color(0xFF60708A),
                ),
              ),
              const SizedBox(height: 18),
              _SectionHeader(
                title: '命名账期',
                actionLabel: '新增账期',
                onTap: () => showPeriodSheet(context, ref),
              ),
              const SizedBox(height: 12),
              if (book.periods.isEmpty)
                const _EmptyCard(label: '还没有命名账期，可以先把旅行、春节或装修单独圈出来。')
              else
                for (final period in book.periods)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PeriodTile(
                      period: period,
                      state: viewState,
                      entryCount: entriesForPeriod(book, period).length,
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: PeriodDetailPage(periodId: period.id),
                        );
                      },
                    ),
                  ),
              const SizedBox(height: 22),
              _SectionHeader(
                title: '预算信封',
                actionLabel: '新增预算',
                onTap: () => showBudgetSheet(context, ref),
              ),
              const SizedBox(height: 12),
              if (book.budgets.isEmpty)
                const _EmptyCard(label: '还没有预算，给高频生活面设个上限吧。')
              else
                for (final budget in book.budgets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _BudgetTile(
                      budget: budget,
                      spentAmount: monthlySpendForCategory(
                        book,
                        budget.categoryId,
                        now,
                      ),
                      viewState: viewState,
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: BudgetDetailPage(budgetId: budget.id),
                        );
                      },
                    ),
                  ),
              const SizedBox(height: 22),
              _SectionHeader(
                title: '生活目标',
                actionLabel: '新增目标',
                onTap: () => showGoalSheet(context, ref),
              ),
              const SizedBox(height: 12),
              if (book.goals.isEmpty)
                const _EmptyCard(label: '目标为空时，很容易觉得钱只是流过。')
              else
                for (final goal in book.goals)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _GoalTile(
                      goal: goal,
                      state: viewState,
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: GoalDetailPage(goalId: goal.id),
                        );
                      },
                    ),
                  ),
              const SizedBox(height: 22),
              _SectionHeader(
                title: '固定支出',
                actionLabel: '新增订阅',
                onTap: () => showSubscriptionSheet(context, ref),
              ),
              const SizedBox(height: 12),
              if (book.subscriptions.isEmpty)
                const _EmptyCard(label: '还没有固定支出计划，订阅和会员最容易漏掉。')
              else
                for (final plan in [
                  ...book.subscriptions,
                ]..sort((a, b) => a.nextChargeAt.compareTo(b.nextChargeAt)))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PlanTile(
                      plan: plan,
                      state: viewState,
                      onTap: () {
                        pushPremiumPage<void>(
                          context,
                          page: SubscriptionDetailPage(planId: plan.id),
                        );
                      },
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<bool> _confirmDestructiveAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '删除',
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

class BudgetDetailPage extends ConsumerWidget {
  const BudgetDetailPage({required this.budgetId, super.key});

  final String budgetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerControllerProvider);
    final book = state.book;
    final budget = book?.budgets.firstWhereOrNull(
      (item) => item.id == budgetId,
    );
    if (book == null || budget == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('预算明细')),
        body: const Center(child: Text('这条预算已不存在。')),
      );
    }

    final now = DateTime.now();
    final category = categoryForId(budget.categoryId);
    final spentAmount = monthlySpendForCategory(book, budget.categoryId, now);
    final remaining = budget.monthlyLimit - spentAmount;
    final progress = budget.monthlyLimit == 0
        ? 0.0
        : (spentAmount / budget.monthlyLimit).clamp(0, 1).toDouble();
    final entries = monthEntriesForCategory(book, now, budget.categoryId);

    return Scaffold(
      appBar: AppBar(title: const Text('预算明细')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: category.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(category.icon, color: category.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              category.name,
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              budget.targetLabel,
                              style: GoogleFonts.plusJakartaSans(
                                color: const Color(0xFF71809A),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '${formatAmount(spentAmount, state)} / ${formatAmount(budget.monthlyLimit, state)}',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 12,
                      value: progress,
                      backgroundColor: const Color(0xFFE8ECF4),
                      valueColor: AlwaysStoppedAnimation(
                        remaining < 0
                            ? const Color(0xFFC44536)
                            : category.color,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    remaining >= 0
                        ? '本月还剩 ${formatAmount(remaining, state)} 可用'
                        : '本月已超出 ${formatAmount(remaining.abs(), state)}',
                    style: GoogleFonts.plusJakartaSans(
                      color: remaining >= 0
                          ? const Color(0xFF60708A)
                          : const Color(0xFFC44536),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        showBudgetSheet(context, ref, initialBudget: budget),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('修改'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      final confirmed = await _confirmDestructiveAction(
                        context,
                        title: '删除预算？',
                        message: '删除后，这个预算的上限和说明会被移除。',
                      );
                      if (!confirmed || !context.mounted) return;
                      await ref
                          .read(ledgerControllerProvider.notifier)
                          .deleteBudget(budget.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('删除'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SectionHeader(title: '本月命中流水', actionLabel: '', onTap: null),
            const SizedBox(height: 12),
            if (entries.isEmpty)
              const _EmptyCard(label: '这个预算本月还没有命中流水。')
            else
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _EntryTile(
                    entry: entry,
                    viewState: state,
                    periodLabel: periodForEntry(book, entry)?.name,
                    onTap: () =>
                        showEntrySheet(context, ref, initialEntry: entry),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class GoalDetailPage extends ConsumerWidget {
  const GoalDetailPage({required this.goalId, super.key});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerControllerProvider);
    final goal = state.book?.goals.firstWhereOrNull(
      (item) => item.id == goalId,
    );
    if (state.book == null || goal == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('目标明细')),
        body: const Center(child: Text('这条目标已不存在。')),
      );
    }

    final remaining = math.max<double>(
      0,
      goal.targetAmount - goal.currentAmount,
    );
    final daysLeft = goal.dueDate.difference(DateTime.now()).inDays;

    return Scaffold(
      appBar: AppBar(title: const Text('目标明细')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    goal.name,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    goal.focusLabel,
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '${(goal.progress * 100).round()}%',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 12,
                      value: goal.progress,
                      backgroundColor: const Color(0xFFE8ECF4),
                      valueColor: const AlwaysStoppedAnimation(
                        Color(0xFF1E6CF7),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '已攒 ${formatAmount(goal.currentAmount, state)} / 目标 ${formatAmount(goal.targetAmount, state)}',
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '还差 ${formatAmount(remaining, state)}，${daysLeft >= 0 ? '距离截止还有 $daysLeft 天' : '已超过截止时间'}',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        showGoalSheet(context, ref, initialGoal: goal),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('修改'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      final confirmed = await _confirmDestructiveAction(
                        context,
                        title: '删除目标？',
                        message: '删除后，这个储蓄目标和当前进度会被移除。',
                      );
                      if (!confirmed || !context.mounted) return;
                      await ref
                          .read(ledgerControllerProvider.notifier)
                          .deleteGoal(goal.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SubscriptionDetailPage extends ConsumerWidget {
  const SubscriptionDetailPage({required this.planId, super.key});

  final String planId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerControllerProvider);
    final book = state.book;
    final plan = book?.subscriptions.firstWhereOrNull(
      (item) => item.id == planId,
    );
    if (book == null || plan == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('计划明细')),
        body: const Center(child: Text('这条固定支出计划已不存在。')),
      );
    }

    final category = categoryForId(plan.categoryId);
    final annualized = round2(plan.amount * (365 / plan.cycleDays));
    final relatedEntries =
        book.entries
            .where(
              (entry) =>
                  entry.type == EntryType.expense &&
                  entry.categoryId == plan.categoryId &&
                  entry.channel == plan.channel,
            )
            .toList()
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    return Scaffold(
      appBar: AppBar(title: const Text('计划明细')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: category.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(category.icon, color: category.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              plan.name,
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${category.name} · ${plan.channel.label}',
                              style: GoogleFonts.plusJakartaSans(
                                color: const Color(0xFF71809A),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    formatAmount(plan.amount, state),
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '每 ${plan.cycleDays} 天一次，下次扣款 ${_compactDateFormatter.format(plan.nextChargeAt)}',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '折算全年约 ${formatAmount(annualized, state)}',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        showSubscriptionSheet(context, ref, initialPlan: plan),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('修改'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      final confirmed = await _confirmDestructiveAction(
                        context,
                        title: '删除固定支出计划？',
                        message: '删除后，这条固定支出计划将不再用于后续安排。',
                      );
                      if (!confirmed || !context.mounted) return;
                      await ref
                          .read(ledgerControllerProvider.notifier)
                          .deleteSubscription(plan.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('删除'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SectionHeader(title: '相关流水', actionLabel: '', onTap: null),
            const SizedBox(height: 12),
            if (relatedEntries.isEmpty)
              const _EmptyCard(label: '当前还没有匹配到这类固定支出的流水。')
            else
              for (final entry in relatedEntries.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _EntryTile(
                    entry: entry,
                    viewState: state,
                    periodLabel: periodForEntry(book, entry)?.name,
                    onTap: () =>
                        showEntrySheet(context, ref, initialEntry: entry),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class InsightsScreen extends StatelessWidget {
  const InsightsScreen({
    required this.book,
    required this.viewState,
    super.key,
  });

  final LedgerBook book;
  final LedgerViewState viewState;

  @override
  Widget build(BuildContext context) {
    final categoryData = categorySpends(book).take(5).toList();
    final pillarData = lifePillarInsights(book);
    final insights = smartInsights(book);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
          sliver: SliverList.list(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '看看钱都花到哪儿了',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => exportLedgerReports(context, book),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('导出统计'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3EEFF),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.assessment_rounded,
                        color: Color(0xFF1E6CF7),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '导出会在手机本地生成统计文件：分类统计表、流水明细表和账本快照。导出前会让你选保存位置。',
                        style: GoogleFonts.plusJakartaSans(
                          color: const Color(0xFF60708A),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '这里把支出结构、各类开销和固定扣款放在一起，方便你看清下一步怎么调整。',
                style: GoogleFonts.plusJakartaSans(
                  color: const Color(0xFF60708A),
                ),
              ),
              const SizedBox(height: 18),
              const LocalAiChatEntry(),
              const SizedBox(height: 12),
              const LocalAiVoiceAskEntry(),
              const SizedBox(height: 18),
              LedgerAnomalyCard(book: book),
              const SizedBox(height: 18),
              MoodConsumptionChartCard(book: book),
              const SizedBox(height: 18),
              _GlassCard(
                child: SizedBox(
                  height: 260,
                  child: categoryData.isEmpty
                      ? const Center(child: Text('暂无足够的支出数据绘制结构图。'))
                      : RepaintBoundary(
                          child: PieChart(
                            duration: const Duration(milliseconds: 620),
                            curve: Curves.easeOutCubic,
                            PieChartData(
                              sectionsSpace: 4,
                              centerSpaceRadius: 56,
                              sections: [
                                for (final item in categoryData)
                                  PieChartSectionData(
                                    value: item.amount,
                                    title: item.category.name,
                                    color: item.category.color,
                                    radius: 56,
                                    titleStyle: GoogleFonts.plusJakartaSans(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 22),
              _SectionHeader(title: '要点提醒', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              for (final insight in insights)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _InsightBulletCard(text: insight),
                ),
              const SizedBox(height: 22),
              _SectionHeader(title: '各类开销一览', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              for (final pillar in pillarData)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _PillarTile(pillar: pillar, state: viewState),
                ),
              const SizedBox(height: 24),
              HeatmapView(book: book),
              const SizedBox(height: 24),
              SankeyView(book: book),
              const SizedBox(height: 24),
              // --- Map Entry Card ---
              _GlassCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF5C6BC0), Color(0xFF7986CB)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.map_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  title: Text(
                    '消费地图',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    '看看每一笔花在哪儿了',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Color(0xFF5C6BC0),
                  ),
                  onTap: () => pushPremiumPage<void>(
                    context,
                    page: LocationSpendMapPage(book: book),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              // --- Region Spend Analysis ---
              _SectionHeader(title: '常去的地方花了多少', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final regions = regionSpendAnalysis(book);
                  if (regions.isEmpty) {
                    return _GlassCard(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '还没有位置记录。打开位置记账后，这里会显示各地的消费占比。',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.plusJakartaSans(
                              color: const Color(0xFF60708A),
                            ),
                          ),
                        ),
                      ),
                    );
                  }
                  final top5 = regions.take(5).toList();
                  final total = top5.fold<double>(0, (s, r) => s + r.amount);
                  const regionColors = [
                    Color(0xFF5C6BC0),
                    Color(0xFF26A69A),
                    Color(0xFFFF7043),
                    Color(0xFFAB47BC),
                    Color(0xFF42A5F5),
                  ];
                  return _GlassCard(
                    child: Column(
                      children: [
                        SizedBox(
                          height: 180,
                          child: RepaintBoundary(
                            child: PieChart(
                              duration: const Duration(milliseconds: 620),
                              curve: Curves.easeOutCubic,
                              PieChartData(
                                sectionsSpace: 3,
                                centerSpaceRadius: 40,
                                sections: [
                                  for (var i = 0; i < top5.length; i++)
                                    PieChartSectionData(
                                      value: top5[i].amount,
                                      title: top5[i].region,
                                      color:
                                          regionColors[i % regionColors.length],
                                      radius: 46,
                                      titleStyle: GoogleFonts.plusJakartaSans(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (var i = 0; i < top5.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color:
                                        regionColors[i % regionColors.length],
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    top5[i].region,
                                    style: GoogleFonts.plusJakartaSans(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${top5[i].count}笔',
                                  style: GoogleFonts.plusJakartaSans(
                                    color: const Color(0xFF7A869C),
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _safeCurrencyFormatter.format(top5[i].amount),
                                  style: GoogleFonts.spaceGrotesk(
                                    fontWeight: FontWeight.w700,
                                    color:
                                        regionColors[i % regionColors.length],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${(top5[i].amount / total * 100).toStringAsFixed(0)}%',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12,
                                    color: const Color(0xFF7A869C),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class VaultScreen extends ConsumerWidget {
  const VaultScreen({required this.book, required this.viewState, super.key});

  final LedgerBook book;
  final LedgerViewState viewState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(ledgerControllerProvider.notifier);
    final autoEntries = book.entries
        .where((entry) => entry.autoCaptured)
        .take(5)
        .toList();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
          sliver: SliverList.list(
            children: [
              Text(
                '隐私与自动记账',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '这里管理加密保存、后台自动锁定，以及微信、支付宝等支付通知的自动记账。',
                style: GoogleFonts.plusJakartaSans(
                  color: const Color(0xFF60708A),
                ),
              ),
              const SizedBox(height: 18),
              _HeroLedgerCard(
                title: '加密保存',
                subtitle: '账单在手机上加密后再存盘',
                amountText: book.settings.confidentialModeEnabled
                    ? '机密模式已开'
                    : '标准加密模式',
                chips: [
                  _HeroChipAction(
                    label: '金额打码 ${book.settings.maskAmounts ? '开启' : '关闭'}',
                  ),
                  _HeroChipAction(
                    label:
                        '后台自动锁定 ${book.settings.quickLockOnBackground ? '开启' : '关闭'}',
                  ),
                  _HeroChipAction(
                    label: '截屏 ${book.settings.allowScreenshots ? '允许' : '禁止'}',
                  ),
                ],
                trailing: IconButton.filledTonal(
                  onPressed: () => controller.lockVault(),
                  icon: const Icon(Icons.lock),
                ),
              ),
              const SizedBox(height: 18),
              LocalAiModelSettingsEntry(book: book),
              const SizedBox(height: 12),
              AutoCapturePipelineCard(book: book),
              const SizedBox(height: 18),
              _GlassCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: book.settings.confidentialModeEnabled,
                      title: const Text('机密模式'),
                      subtitle: const Text('默认打码金额，适合公共场景使用'),
                      onChanged: (value) {
                        controller.updateSettings(
                          book.settings.copyWith(
                            confidentialModeEnabled: value,
                            maskAmounts: value
                                ? true
                                : book.settings.maskAmounts,
                            quickLockOnBackground: value
                                ? true
                                : book.settings.quickLockOnBackground,
                          ),
                        );
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: book.settings.maskAmounts,
                      title: const Text('金额打码'),
                      subtitle: const Text('总览、洞察和流水默认隐藏金额'),
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(maskAmounts: value),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: book.settings.quickLockOnBackground,
                      title: const Text('后台快速锁定'),
                      subtitle: const Text('切到后台时立即锁住账本'),
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(quickLockOnBackground: value),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: book.settings.allowScreenshots,
                      title: const Text('允许截屏'),
                      subtitle: const Text('关闭后，系统截屏和录屏将被阻止'),
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(allowScreenshots: value),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: book.settings.biometricUnlockEnabled,
                      title: const Text('指纹解锁'),
                      subtitle: Text(
                        viewState.biometricAvailable
                            ? '首次需手动口令解锁一次，开启后会把口令安全保存在本机加密存储里，之后可直接用指纹进入。'
                            : '当前设备没有可用的指纹或生物识别，暂时无法启用。',
                      ),
                      onChanged: (value) =>
                          controller.updateBiometricUnlockEnabled(value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: book.settings.autoCaptureEnabled,
                      title: const Text('自动记账主开关'),
                      subtitle: const Text('统一控制通知抓取导入'),
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(autoCaptureEnabled: value),
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: resolveDefaultExpenseCategoryId(book.settings),
                      decoration: const InputDecoration(
                        labelText: '自动记账默认分类',
                        helperText: '分类由千问生成；这里只是千问没能给出结果时的备用分类。',
                      ),
                      items: [
                        for (final category in categoriesForType(
                          EntryType.expense,
                        ))
                          DropdownMenuItem(
                            value: category.id,
                            child: Text(category.name),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        controller.updateSettings(
                          book.settings.copyWith(
                            defaultExpenseCategoryId: value,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _SectionHeader(
                title: '通知接入',
                actionLabel: viewState.notificationAccessGranted
                    ? '去同步'
                    : '去授权',
                onTap: () {
                  if (viewState.notificationAccessGranted) {
                    controller.syncAutoCapturedEntries();
                  } else {
                    controller.openNotificationAccessSettings();
                  }
                },
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Column(
                  children: [
                    _ToggleRow(
                      title: '通知读取权限',
                      value: viewState.notificationAccessGranted
                          ? '已开启'
                          : '未开启',
                      accent: viewState.notificationAccessGranted
                          ? const Color(0xFF0FA968)
                          : const Color(0xFFC44536),
                    ),
                    const SizedBox(height: 12),
                    _SourceSwitchTile(
                      title: '微信支付',
                      value: book.settings.wechatEnabled,
                      subtitle: '适合餐饮、家庭、宠物等高频生活支付',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(wechatEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: '支付宝',
                      value: book.settings.alipayEnabled,
                      subtitle: '适合出行、缴费、运动与服务场景',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(alipayEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: 'Google Pay',
                      value: book.settings.googlePayEnabled,
                      subtitle: '适合海外订阅、数字服务和钱包支付',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(googlePayEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: '淘宝',
                      value: book.settings.taobaoEnabled,
                      subtitle: '适合淘宝下单、订单支付和退款通知',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(taobaoEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: '京东',
                      value: book.settings.jdEnabled,
                      subtitle: '适合京东订单支付、退款和售后回款',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(jdEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: '拼多多',
                      value: book.settings.pinduoduoEnabled,
                      subtitle: '适合拼多多订单付款和退款自动入账',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(pinduoduoEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: '闲鱼',
                      value: book.settings.xianyuEnabled,
                      subtitle: '适合买卖双方收付款与退款场景',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(xianyuEnabled: value),
                      ),
                    ),
                    _SourceSwitchTile(
                      title: '银行卡通知',
                      value: book.settings.bankEnabled,
                      subtitle: '工行/建行/农行/中行/交行/邮储等银行 APP 通知',
                      onChanged: (value) => controller.updateSettings(
                        book.settings.copyWith(bankEnabled: value),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _SectionHeader(title: '语音输入', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              _GlassCard(
                child: _SourceSwitchTile(
                  title: '语音/文字速记',
                  value: book.settings.voiceInputEnabled,
                  subtitle: '开启后主页显示语音输入按钮，支持离线中文语音识别',
                  onChanged: (value) => controller.updateSettings(
                    book.settings.copyWith(voiceInputEnabled: value),
                  ),
                ),
              ),

              const SizedBox(height: 22),
              _SectionHeader(title: '位置与常用地点', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              _GlassCard(
                child: Column(
                  children: [
                    DropdownButtonFormField<LocationTrackingMode>(
                      value: book.settings.locationMode,
                      decoration: const InputDecoration(labelText: '记录位置的方式'),
                      items: const [
                        DropdownMenuItem(
                          value: LocationTrackingMode.off,
                          child: Text('关闭位置记录'),
                        ),
                        DropdownMenuItem(
                          value: LocationTrackingMode.foregroundLazy,
                          child: Text('用当前定位（推荐）'),
                        ),
                        DropdownMenuItem(
                          value: LocationTrackingMode.ipRough,
                          child: Text('只记网络大致位置（不精确）'),
                        ),
                        DropdownMenuItem(
                          value: LocationTrackingMode.backgroundPrecise,
                          child: Text('每次重新定位（会慢一点）'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        controller.updateSettings(
                          book.settings.copyWith(locationMode: value),
                        );
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F5E9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.location_on,
                          color: Color(0xFF43A047),
                          size: 20,
                        ),
                      ),
                      title: const Text('自动记账记录位置'),
                      subtitle: const Text('自动记账时顺便记下当前位置'),
                      value: book.settings.autoRecordLocation,
                      onChanged: (value) {
                        controller.updateSettings(
                          book.settings.copyWith(autoRecordLocation: value),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.bookmark_rounded,
                          color: Color(0xFFFF7043),
                          size: 20,
                        ),
                      ),
                      title: const Text('常用地点管理'),
                      subtitle: Text(
                        '已收藏 ${book.favoriteLocations.length} 个地点',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => pushPremiumPage<void>(
                        context,
                        page: FavoriteLocationsPage(book: book),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8EAF6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.rule,
                          color: Color(0xFF5C6BC0),
                          size: 20,
                        ),
                      ),
                      title: const Text('自定义分类规则'),
                      subtitle: Text('已配置 ${book.customRules.length} 条规则'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => pushPremiumPage<void>(
                        context,
                        page: SettingsCustomRulesView(book: book),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8EAF6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.account_balance_wallet,
                          color: Color(0xFF5C6BC0),
                          size: 20,
                        ),
                      ),
                      title: const Text('资金账户池'),
                      subtitle: Text('已绑定 ${book.assetAccounts.length} 个期初资产'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => pushPremiumPage<void>(
                        context,
                        page: AssetAccountsView(book: book),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),
              _SectionHeader(
                title: '备份与隐私',
                actionLabel: '查看说明',
                onTap: () => pushPremiumPage<void>(
                  context,
                  page: PrivacyNoticePage(
                    settings: book.settings,
                    biometricAvailable: viewState.biometricAvailable,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '加密备份会保存为本地单文件，导出时需要你设置备份密码；导入时也必须输入这份备份对应的密码才能解密，并继续使用你当前的保险库口令重新加密，不会上传到云端。',
                      style: GoogleFonts.plusJakartaSans(
                        color: const Color(0xFF60708A),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: () =>
                            exportEncryptedLedgerBackup(context, book),
                        icon: const Icon(Icons.ios_share_rounded),
                        label: const Text('导出加密备份'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            pickAndImportLedgerBackup(context, ref),
                        icon: const Icon(Icons.upload_file_outlined),
                        label: const Text('导入加密备份'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => pushPremiumPage<void>(
                          context,
                          page: PrivacyNoticePage(
                            settings: book.settings,
                            biometricAvailable: viewState.biometricAvailable,
                          ),
                        ),
                        icon: const Icon(Icons.privacy_tip_outlined),
                        label: const Text('隐私说明'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _SectionHeader(title: '最近自动入账', actionLabel: '', onTap: null),
              const SizedBox(height: 12),
              if (autoEntries.isEmpty)
                const _EmptyCard(label: '自动记账还没有导入记录，先去打开通知读取权限。')
              else
                for (final entry in autoEntries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _EntryTile(
                      entry: entry,
                      viewState: viewState,
                      periodLabel: periodForEntry(book, entry)?.name,
                      onTap: () =>
                          showEntrySheet(context, ref, initialEntry: entry),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class PrivacyNoticePage extends StatelessWidget {
  const PrivacyNoticePage({
    required this.settings,
    required this.biometricAvailable,
    super.key,
  });

  final VaultSettings settings;
  final bool biometricAvailable;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F7FB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          '隐私说明',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            '潮汐账本默认把数据留在本机，并尽量把自动记账控制在支付通知范围内。',
            style: GoogleFonts.plusJakartaSans(
              color: const Color(0xFF60708A),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _FeatureBullet('账本内容默认保存在当前设备，并通过标准 AES-GCM 加密后再落盘。'),
                _FeatureBullet('自动记账只读取系统通知里的支付相关文本，不会抓取聊天记录数据库或支付 App 私有数据。'),
                _FeatureBullet('加密备份会保存为本地单文件，导出时需要单独设置备份密码，不会默认上传到任何云端。'),
                _FeatureBullet(
                  '导入加密备份会先要求输入备份密码，解密成功后才会替换当前账本内容，并继续使用你当前的保险库口令重新加密。',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前设备隐私状态',
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 14),
                _ToggleRow(
                  title: '截屏',
                  value: settings.allowScreenshots ? '已允许' : '已禁止',
                  accent: settings.allowScreenshots
                      ? const Color(0xFF1E6CF7)
                      : const Color(0xFFC44536),
                ),
                const SizedBox(height: 10),
                _ToggleRow(
                  title: '指纹解锁',
                  value: settings.biometricUnlockEnabled ? '已开启' : '未开启',
                  accent: settings.biometricUnlockEnabled
                      ? const Color(0xFF0FA968)
                      : const Color(0xFF7A869C),
                ),
                const SizedBox(height: 10),
                _ToggleRow(
                  title: '生物识别能力',
                  value: biometricAvailable ? '可用' : '不可用',
                  accent: biometricAvailable
                      ? const Color(0xFF0FA968)
                      : const Color(0xFFC44536),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _FeatureBullet('如果你开启“允许截屏”，系统截屏和录屏会恢复；关闭后会启用 Android 安全窗口。'),
                _FeatureBullet('如果你开启“指纹解锁”，口令只会保存在当前设备的加密安全存储里，用于下次指纹解锁。'),
                _FeatureBullet(
                  '购物平台付款会尽量合并到微信、支付宝或 Google Pay 的主支付记录里，避免重复记账。',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PeriodDetailPage extends ConsumerWidget {
  const PeriodDetailPage({required this.periodId, super.key});

  final String periodId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerControllerProvider);
    final book = state.book;
    final period = book?.periods.firstWhereOrNull(
      (item) => item.id == periodId,
    );
    if (book == null || period == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('账期明细')),
        body: const Center(child: Text('这段命名账期已不存在。')),
      );
    }

    final entries = entriesForPeriod(book, period);
    final income = round2(
      entries
          .where((entry) => entry.type == EntryType.income)
          .fold<double>(0, (sum, entry) => sum + entry.amount),
    );
    final expense = round2(
      entries
          .where((entry) => entry.type == EntryType.expense)
          .fold<double>(0, (sum, entry) => sum + entry.amount),
    );
    final categorySpend =
        appCategories
            .where((category) => category.type == EntryType.expense)
            .map(
              (category) => (
                category,
                round2(
                  entries
                      .where(
                        (entry) =>
                            entry.type == EntryType.expense &&
                            entry.categoryId == category.id,
                      )
                      .fold<double>(0, (sum, entry) => sum + entry.amount),
                ),
              ),
            )
            .where((item) => item.$2 > 0)
            .toList()
          ..sort((a, b) => b.$2.compareTo(a.$2));

    return Scaffold(
      appBar: AppBar(title: const Text('账期明细')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    period.name,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_compactDateFormatter.format(period.startAt)} - ${_compactDateFormatter.format(period.endAt)}',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A),
                    ),
                  ),
                  if (period.note.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      period.note.trim(),
                      style: GoogleFonts.plusJakartaSans(
                        color: const Color(0xFF60708A),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _MetricCard(
                          label: '收入',
                          value: formatAmount(income, state),
                          detail:
                              '${entries.where((e) => e.type == EntryType.income).length} 笔',
                          accent: const Color(0xFF11A66A),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MetricCard(
                          label: '支出',
                          value: formatAmount(expense, state),
                          detail:
                              '${entries.where((e) => e.type == EntryType.expense).length} 笔',
                          accent: const Color(0xFF5E83FF),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _MetricCard(
                    label: '净额',
                    value: formatAmount(income - expense, state, signed: true),
                    detail: '账期内共 ${entries.length} 笔流水',
                    accent: const Color(0xFF2E4A86),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        showPeriodSheet(context, ref, initialPeriod: period),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('修改'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      final confirmed = await _confirmDestructiveAction(
                        context,
                        title: '删除命名账期？',
                        message: '删除后流水会保留，只是不再展示这段账期归属。',
                      );
                      if (!confirmed || !context.mounted) return;
                      await ref
                          .read(ledgerControllerProvider.notifier)
                          .deletePeriod(period.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('删除'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SectionHeader(title: '分类分布', actionLabel: '', onTap: null),
            const SizedBox(height: 12),
            if (categorySpend.isEmpty)
              const _EmptyCard(label: '这段账期里还没有支出分类数据。')
            else
              for (final item in categorySpend.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _CategorySpendTile(
                    category: item.$1,
                    amount: item.$2,
                    state: state,
                  ),
                ),
            const SizedBox(height: 22),
            _SectionHeader(title: '账期流水', actionLabel: '', onTap: null),
            const SizedBox(height: 12),
            if (entries.isEmpty)
              const _EmptyCard(label: '这段账期里还没有流水。')
            else
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _EntryTile(
                    entry: entry,
                    viewState: state,
                    periodLabel: period.name,
                    onTap: () =>
                        showEntrySheet(context, ref, initialEntry: entry),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

DateTime _combineDateAndTime(DateTime date, TimeOfDay time) {
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

List<String> _parseEntryTags(String raw) {
  return raw
      .split(RegExp(r'[\\n,，|]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();
}

List<String> _buildManualOverrideFields(
  LedgerEntry original,
  LedgerEntry updated,
) {
  final fields = {...original.manualOverrideFields};
  if (original.title != updated.title) fields.add('title');
  if (original.merchant != updated.merchant) fields.add('merchant');
  if (original.counterpartyName != updated.counterpartyName) {
    fields.add('counterpartyName');
  }
  if (original.note != updated.note) fields.add('note');
  if ((original.amount - updated.amount).abs() > 0.009) fields.add('amount');
  if (original.type != updated.type) fields.add('type');
  if (original.categoryId != updated.categoryId) fields.add('categoryId');
  if (original.channel != updated.channel) fields.add('channel');
  if (original.occurredAt != updated.occurredAt) fields.add('occurredAt');
  if (!const ListEquality<String>().equals(original.tags, updated.tags)) {
    fields.add('tags');
  }
  return fields.toList()..sort();
}

Future<void> showEntrySheet(
  BuildContext context,
  WidgetRef ref, {
  EntryType forcedType = EntryType.expense,
  LedgerEntry? initialEntry,
}) async {
  final book = ref.read(ledgerControllerProvider).book;
  if (book == null) return;

  final initialType = initialEntry == null
      ? forcedType
      : (initialEntry.type == EntryType.income
            ? EntryType.income
            : EntryType.expense);
  final initialMoment = initialEntry?.occurredAt ?? DateTime.now();
  final defaultExpenseCategoryId = resolveDefaultExpenseCategoryId(
    book.settings,
  );
  final titleController = TextEditingController(
    text: initialEntry?.title ?? '',
  );
  final merchantController = TextEditingController(
    text: initialEntry?.merchant == initialEntry?.title
        ? ''
        : (initialEntry?.merchant ?? ''),
  );
  final counterpartyController = TextEditingController(
    text: initialEntry?.counterpartyName ?? '',
  );
  final noteController = TextEditingController(text: initialEntry?.note ?? '');
  final amountController = TextEditingController(
    text: initialEntry == null ? '' : initialEntry.amount.toStringAsFixed(2),
  );
  final tagsController = TextEditingController(
    text: initialEntry?.tags.join('，') ?? '',
  );
  final locationController = TextEditingController(
    text: initialEntry?.locationInfo ?? '',
  );
  var type = initialType;
  var channel = initialEntry?.channel ?? PaymentChannel.wechatPay;
  var selectedMood = initialEntry?.mood ?? ExpenseMood.none;
  var categoryId =
      initialEntry?.categoryId ??
      (initialType == EntryType.expense
          ? defaultExpenseCategoryId
          : categoriesForType(initialType).first.id);
  var selectedDate = DateTime(
    initialMoment.year,
    initialMoment.month,
    initialMoment.day,
  );
  var selectedTime = TimeOfDay.fromDateTime(initialMoment);
  double? entryLat = initialEntry?.latitude;
  double? entryLon = initialEntry?.longitude;
  var nearbySummary = '';

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          final availableCategories = appCategories
              .where((item) => item.type == type)
              .toList();
          if (!availableCategories.any((item) => item.id == categoryId)) {
            categoryId = type == EntryType.expense
                ? defaultExpenseCategoryId
                : availableCategories.first.id;
          }

          return _SheetScaffold(
            title: initialEntry == null ? '新增${type.label}' : '修改流水',
            child: Column(
              children: [
                SegmentedButton<EntryType>(
                  segments: const [
                    ButtonSegment(value: EntryType.expense, label: Text('支出')),
                    ButtonSegment(value: EntryType.income, label: Text('收入')),
                  ],
                  selected: {type},
                  onSelectionChanged: (selection) {
                    setModalState(() => type = selection.first);
                  },
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: merchantController,
                  decoration: const InputDecoration(labelText: '商户 / 店铺'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: counterpartyController,
                  decoration: const InputDecoration(labelText: '付款人 / 收款方'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '金额'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: categoryId,
                  decoration: const InputDecoration(labelText: '类别'),
                  items: [
                    for (final category in availableCategories)
                      DropdownMenuItem(
                        value: category.id,
                        child: Text(category.name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setModalState(() => categoryId = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<PaymentChannel>(
                  value: channel,
                  decoration: const InputDecoration(labelText: '支付渠道'),
                  items: [
                    for (final item in PaymentChannel.values)
                      DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setModalState(() => channel = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tagsController,
                  decoration: const InputDecoration(labelText: '标签（用逗号分隔）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationController,
                  decoration: InputDecoration(
                    labelText: '地址 / 位置',
                    prefixIcon: const Icon(Icons.location_on_outlined),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (book.favoriteLocations.isNotEmpty)
                          IconButton(
                            icon: const Icon(
                              Icons.bookmark_rounded,
                              color: Color(0xFFFF7043),
                            ),
                            tooltip: '从收藏选择',
                            onPressed: () async {
                              final selected =
                                  await showModalBottomSheet<FavoriteLocation>(
                                    context: context,
                                    builder: (ctx) => Container(
                                      padding: const EdgeInsets.all(20),
                                      decoration: const BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(24),
                                        ),
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '常用地点',
                                            style: GoogleFonts.spaceGrotesk(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          ...book.favoriteLocations.map(
                                            (fav) => ListTile(
                                              leading: const Icon(
                                                Icons.location_on,
                                                color: Color(0xFF5C6BC0),
                                              ),
                                              title: Text(
                                                fav.name,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              subtitle: Text(
                                                fav.address,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              trailing: fav.categoryId != null
                                                  ? Icon(
                                                      categoryForId(
                                                        fav.categoryId!,
                                                      ).icon,
                                                      color: categoryForId(
                                                        fav.categoryId!,
                                                      ).color,
                                                      size: 18,
                                                    )
                                                  : null,
                                              onTap: () =>
                                                  Navigator.of(ctx).pop(fav),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                              if (selected != null) {
                                setModalState(() {
                                  locationController.text = selected.address;
                                  entryLat = selected.latitude;
                                  entryLon = selected.longitude;
                                  // Apply template defaults
                                  if (selected.defaultTitle != null &&
                                      selected.defaultTitle!.isNotEmpty &&
                                      titleController.text.isEmpty) {
                                    titleController.text =
                                        selected.defaultTitle!;
                                  }
                                  if (selected.defaultAmount != null &&
                                      amountController.text.isEmpty) {
                                    amountController.text = selected
                                        .defaultAmount!
                                        .toStringAsFixed(2);
                                  }
                                  if (selected.categoryId != null) {
                                    categoryId = selected.categoryId!;
                                  }
                                  nearbySummary = nearbySummaryForLocation(
                                    book,
                                    selected.address,
                                  );
                                });
                              }
                            },
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.my_location,
                            color: Color(0xFF5C6BC0),
                          ),
                          tooltip: '自动获取当前位置',
                          onPressed: () async {
                            setModalState(() {
                              locationController.text = '正在定位...';
                            });
                            try {
                              final locResult =
                                  await LocationHelper.getDetailedLocation();
                              if (!context.mounted) return;
                              if (locResult.isNotEmpty) {
                                entryLat = locResult.latitude;
                                entryLon = locResult.longitude;
                                // Check favorite match
                                final matchedFav =
                                    LocationHelper.findNearestFavorite(
                                      locResult.latitude,
                                      locResult.longitude,
                                      book.favoriteLocations,
                                    );
                                if (matchedFav != null) {
                                  if (matchedFav.defaultTitle != null &&
                                      matchedFav.defaultTitle!.isNotEmpty &&
                                      titleController.text.isEmpty) {
                                    titleController.text =
                                        matchedFav.defaultTitle!;
                                  }
                                  if (matchedFav.defaultAmount != null &&
                                      amountController.text.isEmpty) {
                                    amountController.text = matchedFav
                                        .defaultAmount!
                                        .toStringAsFixed(2);
                                  }
                                  if (matchedFav.categoryId != null &&
                                      context.mounted) {
                                    setModalState(
                                      () => categoryId = matchedFav.categoryId!,
                                    );
                                  }
                                }
                                // Smart category from POI
                                try {
                                  final poi = await LocationHelper.getNearbyPOI(
                                    locResult.latitude,
                                    locResult.longitude,
                                  );
                                  if (!context.mounted) return;
                                  if (poi.isNotEmpty) {
                                    final suggestedCat =
                                        LocationHelper.suggestCategoryFromPOI(
                                          poi,
                                        );
                                    if (suggestedCat != null &&
                                        matchedFav?.categoryId == null) {
                                      setModalState(
                                        () => categoryId = suggestedCat,
                                      );
                                    }
                                    if (merchantController.text.isEmpty) {
                                      merchantController.text = poi;
                                    }
                                  }
                                } catch (_) {}
                                if (context.mounted) {
                                  setModalState(() {
                                    locationController.text =
                                        locResult.address.isNotEmpty
                                        ? locResult.address
                                        : '';
                                    nearbySummary = nearbySummaryForLocation(
                                      book,
                                      locResult.address,
                                    );
                                  });
                                }
                              } else {
                                if (context.mounted) {
                                  setModalState(() {
                                    locationController.text = '';
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('无法获取位置，请检查定位权限或GPS是否开启。'),
                                    ),
                                  );
                                }
                              }
                            } catch (_) {
                              if (context.mounted) {
                                setModalState(() {
                                  locationController.text = '';
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('定位失败，请稍后重试。')),
                                );
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                if (nearbySummary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8EAF6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Color(0xFF5C6BC0),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              nearbySummary,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                color: const Color(0xFF3F51B5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  minLines: 3,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                const SizedBox(height: 12),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '这一单的心情状态: ${selectedMood.label} ${selectedMood.emoji}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: ExpenseMood.values.map((m) {
                          final isSelected = selectedMood == m;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: FilterChip(
                              label: Text(m.emoji),
                              selected: isSelected,
                              onSelected: (val) {
                                setModalState(() => selectedMood = m);
                              },
                              selectedColor: m.color.withValues(alpha: 0.2),
                              side: isSelected
                                  ? BorderSide(color: m.color, width: 2)
                                  : null,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  tileColor: const Color(0xFFF2F5FA),
                  title: const Text('记账日期'),
                  subtitle: Text(_compactDateFormatter.format(selectedDate)),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      firstDate: DateTime(DateTime.now().year - 2),
                      lastDate: DateTime(DateTime.now().year + 2),
                      initialDate: selectedDate,
                    );
                    if (picked != null) {
                      setModalState(() => selectedDate = picked);
                    }
                  },
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  tileColor: const Color(0xFFF2F5FA),
                  title: const Text('记账时间'),
                  subtitle: Text(selectedTime.format(context)),
                  trailing: const Icon(Icons.access_time_rounded),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: selectedTime,
                    );
                    if (picked != null) {
                      setModalState(() => selectedTime = picked);
                    }
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      final amount = double.tryParse(
                        amountController.text.trim(),
                      );
                      if (titleController.text.trim().isEmpty ||
                          amount == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先填写标题和正确金额。')),
                        );
                        return;
                      }

                      final occurredAt = _combineDateAndTime(
                        selectedDate,
                        selectedTime,
                      );
                      final parsedTags = _parseEntryTags(tagsController.text);
                      final merchantText = merchantController.text.trim();
                      final merchant = merchantText.isEmpty
                          ? (initialEntry == null
                                ? titleController.text.trim()
                                : '')
                          : merchantText;

                      if (initialEntry == null) {
                        await ref
                            .read(ledgerControllerProvider.notifier)
                            .addEntry(
                              LedgerEntry(
                                id: _uuid.v4(),
                                title: titleController.text.trim(),
                                merchant: merchant,
                                counterpartyName: counterpartyController.text
                                    .trim(),
                                note: noteController.text.trim(),
                                amount: amount,
                                type: type,
                                categoryId: categoryId,
                                channel: channel,
                                occurredAt: occurredAt,
                                tags: parsedTags,
                                locationInfo: locationController.text.trim(),
                                latitude: locationController.text.trim().isEmpty
                                    ? null
                                    : entryLat,
                                longitude:
                                    locationController.text.trim().isEmpty
                                    ? null
                                    : entryLon,
                                mood: selectedMood,
                                autoCaptured: false,
                                sourceLabel: '',
                              ),
                            );
                      } else {
                        final edited = initialEntry.copyWith(
                          title: titleController.text.trim(),
                          merchant: merchant,
                          counterpartyName: counterpartyController.text.trim(),
                          note: noteController.text.trim(),
                          amount: amount,
                          type: type,
                          categoryId: categoryId,
                          channel: channel,
                          occurredAt: occurredAt,
                          tags: parsedTags,
                          locationInfo: locationController.text.trim(),
                          latitude: locationController.text.trim().isEmpty
                              ? null
                              : entryLat,
                          longitude: locationController.text.trim().isEmpty
                              ? null
                              : entryLon,
                          mood: selectedMood,
                        );
                        final protected = edited.copyWith(
                          manualOverrideFields: initialEntry.autoCaptured
                              ? _buildManualOverrideFields(initialEntry, edited)
                              : initialEntry.manualOverrideFields,
                        );
                        await ref
                            .read(ledgerControllerProvider.notifier)
                            .updateEntry(protected);
                      }

                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Text(initialEntry == null ? '保存流水' : '保存修改'),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<void> showBudgetSheet(
  BuildContext context,
  WidgetRef ref, {
  BudgetEnvelope? initialBudget,
}) async {
  final limitController = TextEditingController(
    text: initialBudget == null
        ? ''
        : initialBudget.monthlyLimit.toStringAsFixed(0),
  );
  final labelController = TextEditingController(
    text: initialBudget?.targetLabel ?? '',
  );
  var categoryId =
      initialBudget?.categoryId ??
      appCategories.firstWhere((item) => item.type == EntryType.expense).id;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatefulBuilder(
      builder: (context, setModalState) {
        return _SheetScaffold(
          title: initialBudget == null ? '新增预算' : '修改预算',
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                value: categoryId,
                decoration: const InputDecoration(labelText: '预算类别'),
                items: [
                  for (final category in appCategories.where(
                    (item) => item.type == EntryType.expense,
                  ))
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setModalState(() => categoryId = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: limitController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '月度上限'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: labelController,
                decoration: const InputDecoration(labelText: '预算说明'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final amount = double.tryParse(limitController.text.trim());
                    if (amount == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入正确的预算金额。')),
                      );
                      return;
                    }
                    ref
                        .read(ledgerControllerProvider.notifier)
                        .addBudget(
                          BudgetEnvelope(
                            id: initialBudget?.id ?? 'budget-$categoryId',
                            categoryId: categoryId,
                            monthlyLimit: amount,
                            targetLabel: labelController.text.trim().isEmpty
                                ? '按生活节奏自主规划'
                                : labelController.text.trim(),
                          ),
                          previousCategoryId: initialBudget?.categoryId,
                        );
                    Navigator.of(context).pop();
                  },
                  child: Text(initialBudget == null ? '保存预算' : '更新预算'),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<void> showGoalSheet(
  BuildContext context,
  WidgetRef ref, {
  SavingsGoal? initialGoal,
}) async {
  final nameController = TextEditingController(text: initialGoal?.name ?? '');
  final targetController = TextEditingController(
    text: initialGoal == null
        ? ''
        : initialGoal.targetAmount.toStringAsFixed(0),
  );
  final currentController = TextEditingController(
    text: initialGoal == null
        ? '0'
        : initialGoal.currentAmount.toStringAsFixed(0),
  );
  final focusController = TextEditingController(
    text: initialGoal?.focusLabel ?? '',
  );
  DateTime dueDate =
      initialGoal?.dueDate ?? DateTime.now().add(const Duration(days: 180));

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatefulBuilder(
      builder: (context, setModalState) {
        return _SheetScaffold(
          title: initialGoal == null ? '新增目标' : '修改目标',
          child: Column(
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '目标名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: targetController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '目标金额'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: currentController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '已攒金额'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: focusController,
                decoration: const InputDecoration(labelText: '意义标签'),
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                tileColor: const Color(0xFFF2F5FA),
                title: const Text('截止日期'),
                subtitle: Text(_compactDateFormatter.format(dueDate)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now().subtract(
                      const Duration(days: 365),
                    ),
                    lastDate: DateTime.now().add(const Duration(days: 1200)),
                    initialDate: dueDate,
                  );
                  if (picked != null) {
                    setModalState(() => dueDate = picked);
                  }
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final target = double.tryParse(
                      targetController.text.trim(),
                    );
                    final current = double.tryParse(
                      currentController.text.trim(),
                    );
                    if (nameController.text.trim().isEmpty ||
                        target == null ||
                        current == null) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('请补全目标信息。')));
                      return;
                    }
                    ref
                        .read(ledgerControllerProvider.notifier)
                        .addGoal(
                          SavingsGoal(
                            id: initialGoal?.id ?? _uuid.v4(),
                            name: nameController.text.trim(),
                            targetAmount: target,
                            currentAmount: current,
                            dueDate: dueDate,
                            focusLabel: focusController.text.trim().isEmpty
                                ? '长期规划'
                                : focusController.text.trim(),
                          ),
                        );
                    Navigator.of(context).pop();
                  },
                  child: Text(initialGoal == null ? '保存目标' : '更新目标'),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<void> showSubscriptionSheet(
  BuildContext context,
  WidgetRef ref, {
  RecurringPlan? initialPlan,
}) async {
  final nameController = TextEditingController(text: initialPlan?.name ?? '');
  final amountController = TextEditingController(
    text: initialPlan == null ? '' : initialPlan.amount.toStringAsFixed(0),
  );
  final cycleController = TextEditingController(
    text: initialPlan == null ? '30' : initialPlan.cycleDays.toString(),
  );
  DateTime nextChargeAt =
      initialPlan?.nextChargeAt ?? DateTime.now().add(const Duration(days: 30));
  String categoryId = initialPlan?.categoryId ?? 'digital';
  PaymentChannel channel = initialPlan?.channel ?? PaymentChannel.googlePay;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatefulBuilder(
      builder: (context, setModalState) {
        return _SheetScaffold(
          title: initialPlan == null ? '新增固定支出' : '修改固定支出',
          child: Column(
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '计划名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '金额'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cycleController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '周期天数'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: categoryId,
                decoration: const InputDecoration(labelText: '归属类别'),
                items: [
                  for (final category in appCategories.where(
                    (item) => item.type == EntryType.expense,
                  ))
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setModalState(() => categoryId = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PaymentChannel>(
                value: channel,
                decoration: const InputDecoration(labelText: '扣款渠道'),
                items: [
                  for (final item in PaymentChannel.values)
                    DropdownMenuItem(value: item, child: Text(item.label)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setModalState(() => channel = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                tileColor: const Color(0xFFF2F5FA),
                title: const Text('下次扣款时间'),
                subtitle: Text(_compactDateFormatter.format(nextChargeAt)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now().subtract(
                      const Duration(days: 30),
                    ),
                    lastDate: DateTime.now().add(const Duration(days: 1200)),
                    initialDate: nextChargeAt,
                  );
                  if (picked != null) {
                    setModalState(() => nextChargeAt = picked);
                  }
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final amount = double.tryParse(
                      amountController.text.trim(),
                    );
                    final cycle = int.tryParse(cycleController.text.trim());
                    if (amount == null ||
                        cycle == null ||
                        nameController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请补全固定支出信息。')),
                      );
                      return;
                    }
                    ref
                        .read(ledgerControllerProvider.notifier)
                        .addSubscription(
                          RecurringPlan(
                            id: initialPlan?.id ?? _uuid.v4(),
                            name: nameController.text.trim(),
                            categoryId: categoryId,
                            amount: amount,
                            cycleDays: cycle,
                            nextChargeAt: nextChargeAt,
                            channel: channel,
                          ),
                        );
                    Navigator.of(context).pop();
                  },
                  child: Text(initialPlan == null ? '保存固定支出' : '更新固定支出'),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<void> showPeriodSheet(
  BuildContext context,
  WidgetRef ref, {
  LedgerPeriod? initialPeriod,
}) async {
  final nameController = TextEditingController(text: initialPeriod?.name ?? '');
  final noteController = TextEditingController(text: initialPeriod?.note ?? '');
  var startAt = initialPeriod?.startAt ?? DateTime.now();
  var endAt =
      initialPeriod?.endAt ?? DateTime.now().add(const Duration(days: 7));
  var startTime = TimeOfDay.fromDateTime(startAt);
  var endTime = TimeOfDay.fromDateTime(endAt);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatefulBuilder(
      builder: (context, setModalState) {
        return _SheetScaffold(
          title: initialPeriod == null ? '新增账期' : '修改账期',
          child: Column(
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '账期名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '账期说明'),
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                tileColor: const Color(0xFFF2F5FA),
                title: const Text('开始时间'),
                subtitle: Text(DateFormat('yyyy-MM-dd HH:mm').format(startAt)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime(DateTime.now().year - 3),
                    lastDate: DateTime(DateTime.now().year + 3),
                    initialDate: startAt,
                  );
                  if (picked != null) {
                    setModalState(
                      () => startAt = _combineDateAndTime(picked, startTime),
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                tileColor: const Color(0xFFF2F5FA),
                title: const Text('开始时刻'),
                subtitle: Text(startTime.format(context)),
                trailing: const Icon(Icons.access_time_rounded),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: startTime,
                  );
                  if (picked != null) {
                    setModalState(() {
                      startTime = picked;
                      startAt = _combineDateAndTime(startAt, startTime);
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                tileColor: const Color(0xFFF2F5FA),
                title: const Text('结束时间'),
                subtitle: Text(DateFormat('yyyy-MM-dd HH:mm').format(endAt)),
                trailing: const Icon(Icons.event_available_rounded),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime(DateTime.now().year - 3),
                    lastDate: DateTime(DateTime.now().year + 3),
                    initialDate: endAt,
                  );
                  if (picked != null) {
                    setModalState(
                      () => endAt = _combineDateAndTime(picked, endTime),
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                tileColor: const Color(0xFFF2F5FA),
                title: const Text('结束时刻'),
                subtitle: Text(endTime.format(context)),
                trailing: const Icon(Icons.more_time_rounded),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: endTime,
                  );
                  if (picked != null) {
                    setModalState(() {
                      endTime = picked;
                      endAt = _combineDateAndTime(endAt, endTime);
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
              Text(
                '账期范围采用“开始时间 ≤ 流水时间 < 结束时间”的规则，彼此不能重叠。',
                style: GoogleFonts.plusJakartaSans(
                  color: const Color(0xFF60708A),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    if (nameController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请先填写账期名称。')),
                      );
                      return;
                    }

                    final message = await ref
                        .read(ledgerControllerProvider.notifier)
                        .upsertPeriod(
                          LedgerPeriod(
                            id: initialPeriod?.id ?? _uuid.v4(),
                            name: nameController.text.trim(),
                            startAt: startAt,
                            endAt: endAt,
                            note: noteController.text.trim(),
                          ),
                        );
                    if (message != null) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(message)));
                      }
                      return;
                    }
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(initialPeriod == null ? '保存账期' : '更新账期'),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        24,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: _GlassCard(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}
