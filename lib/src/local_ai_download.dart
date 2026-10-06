part of 'app.dart';

/// 安卓系统下载服务返回的状态。下载在系统里进行，退出应用也会继续。
class LocalAiDownloadStatus {
  const LocalAiDownloadStatus({
    required this.state,
    required this.received,
    required this.total,
    required this.reason,
    this.attempts = 0,
    this.maxAttempts = 0,
    this.retryInSeconds = 0,
  });

  final String state;
  final int received;
  final int total;
  final int reason;

  /// 已经自动重试的次数，以及最多重试几次。
  final int attempts;
  final int maxAttempts;

  /// 距离下一次自动重试还有几秒。
  final int retryInSeconds;

  static const idle = LocalAiDownloadStatus(
    state: 'idle',
    received: 0,
    total: 0,
    reason: 0,
  );

  bool get isActive =>
      state == 'pending' || state == 'running' || state == 'paused';

  bool get isRetrying => state == 'failed' && attempts > 0;

  bool get isExhausted => state == 'failed' && attempts >= maxAttempts;

  double? get progress => total > 0
      ? (received / total).clamp(0.0, state == 'successful' ? 1.0 : 0.99)
      : null;

  String get sizeText => total > 0
      ? '${_megabytes(received)} / ${_megabytes(total)} MB'
      : '正在连接下载地址…';

  static String _megabytes(int bytes) =>
      (bytes / 1000000).toStringAsFixed(bytes >= 100000000 ? 0 : 1);

  String get chineseStatus => switch (state) {
    'pending' => '正在准备下载…',
    'running' => '正在后台下载',
    'paused' => switch (reason) {
      1 => '网络断了，系统会自动接着下',
      2 => '正在等网络恢复',
      3 => '正在等无线网络',
      _ => '下载暂时停下，系统会自动接着下',
    },
    'successful' => '文件下载完成，正在校验…',
    'failed' => _failedText,
    _ => '还没有下载',
  };

  String get _failedText {
    final base = switch (reason) {
      1000 => '下载服务出了点问题',
      1001 => '手机存储读写出错',
      1002 => '下载地址返回的内容不对',
      1003 => '下载到一半网络断了',
      1004 => '下载地址跳转太多次',
      1005 => '手机存储空间不够',
      1006 => '找不到存储位置',
      1007 => '文件已经存在',
      1008 => '下载被系统拦住了',
      >= 400 && < 500 => '下载地址返回 $reason，可能已经失效',
      >= 500 => '下载服务器暂时出错（$reason）',
      _ => '下载中断（代码 $reason）',
    };
    if (attempts > 0 && attempts < maxAttempts) {
      final wait = retryInSeconds > 0
          ? '，$retryInSeconds 秒后自动重试'
          : '，马上自动重试';
      return '$base$wait（第 ${attempts + 1} 次，共 $maxAttempts 次）';
    }
    if (attempts >= maxAttempts && maxAttempts > 0) {
      return '$base，已自动重试 $maxAttempts 次仍未成功。可以换个下载地址，或等网络好一点再试';
    }
    return '$base，可以点“继续下载”再试一次';
  }

  factory LocalAiDownloadStatus.fromMap(Map<dynamic, dynamic> map) =>
      LocalAiDownloadStatus(
        state: map['state'] as String? ?? 'idle',
        received: (map['received'] as num?)?.toInt() ?? 0,
        total: (map['total'] as num?)?.toInt() ?? 0,
        reason: (map['reason'] as num?)?.toInt() ?? 0,
        attempts: (map['attempts'] as num?)?.toInt() ?? 0,
        maxAttempts: (map['maxAttempts'] as num?)?.toInt() ?? 0,
        retryInSeconds: (map['retryInSeconds'] as num?)?.toInt() ?? 0,
      );
}

class LocalAiDownloadBridge {
  const LocalAiDownloadBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.aline.jier/model_download',
  );

  Future<LocalAiDownloadStatus> start(
    LocalAiModel model, {
    required bool useMirror,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('start', {
      'modelId': model.id,
      'url': useMirror ? model.mirrorUrl : model.url,
      'alternateUrl': useMirror ? model.url : model.mirrorUrl,
      'title': model.title,
    });
    return LocalAiDownloadStatus.fromMap(result ?? const {});
  }

  Future<LocalAiDownloadStatus> query(LocalAiModel model) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('query', {
      'modelId': model.id,
    });
    return LocalAiDownloadStatus.fromMap(result ?? const {});
  }

  Future<void> cancel(LocalAiModel model) async {
    await _channel.invokeMethod<void>('cancel', {'modelId': model.id});
  }

  /// 本机的本地推理库是否可用。
  Future<bool> canRunLocalAi() async =>
      await _channel.invokeMethod<bool>('canRunLocalAi') ?? false;
}

/// 本机能不能真正跑千问：架构支持还不够，原生库也必须能加载。
class LocalAiCapability {
  static bool? _cached;
  static Future<bool>? _pending;

  /// true = 确定能跑；false = 确定跑不了。
  /// 通道本身出错（拿不到确定答案）时会返回 true，让用户可以先试，
  /// 免得把"通道问题"当成"手机不兼容"。
  static Future<bool> canRun() async {
    final cached = _cached;
    if (cached != null) return cached;
    final pending = _pending;
    if (pending != null) return pending;
    final future = () async {
      var result = false;
      if (localAiInferenceSupported) {
        try {
          result = await const LocalAiDownloadBridge().canRunLocalAi();
        } on MissingPluginException {
          result = true;
        } catch (_) {
          result = true;
        }
      }
      _cached = result;
      _pending = null;
      return result;
    }();
    _pending = future;
    return future;
  }

  /// 架构本身就不支持（32 位手机、x86 模拟器）。
  static bool get architectureUnsupported => !localAiInferenceSupported;

  static String get unavailableMessage => architectureUnsupported
      ? localAiDeviceNotice
      : '这台手机是 64 位 ARM，但推理库没能加载成功（多半是安装包不完整或系统限制）。'
            '请重新安装最新版 App；如果还是这样，把「设置 → 离线千问 → AI 自检」'
            '那一屏截图发给开发者。';
}

Future<String> _downloadedLocalAiModelPath(LocalAiModel model) async {
  final directory = await getExternalStorageDirectory();
  if (directory == null) throw const FileSystemException('手机存储空间不可用');
  final downloadDirectory = Directory('${directory.path}/Download');
  await downloadDirectory.create(recursive: true);
  return '${downloadDirectory.path}/${model.id}.gguf';
}

Future<String> _legacyLocalAiModelPath(LocalAiModel model) async {
  final directory = Directory(
    '${(await getApplicationSupportDirectory()).path}/local_ai_models',
  );
  await directory.create(recursive: true);
  return '${directory.path}/${model.id}.gguf';
}

Future<bool> _isVerifiedLocalAiFile(String path, LocalAiModel model) async {
  try {
    final marker = File('$path.verified');
    return await File(path).exists() &&
        await marker.exists() &&
        (await marker.readAsString()).trim() == model.sha256;
  } on FileSystemException {
    return false;
  }
}

/// 系统下载服务把文件写成 .partial，校验通过后才改名成正式文件。
/// 返回 true 表示这次校验后模型已经可用。
Future<bool> _verifyCompletedLocalAiDownload(LocalAiModel model) async {
  if (await _isInstalled(model)) return true;
  final target = await _downloadedLocalAiModelPath(model);
  final pending = File('$target.partial');
  if (!await pending.exists()) {
    throw const FileSystemException('下载文件不见了，请重新下载');
  }
  final digest = await Isolate.run(() => _hashLocalAiFile(pending.path));
  if (digest != model.sha256) {
    await pending.delete();
    throw const FormatException('文件校验没有通过，已删掉损坏的文件，请重新下载');
  }
  final targetFile = File(target);
  if (await targetFile.exists()) await targetFile.delete();
  await pending.rename(target);
  await File('$target.verified').writeAsString(model.sha256, flush: true);
  return true;
}

/// 判断是否可以进入校验。
///
/// 注意：安卓下载服务会先把文件预分配成完整大小，所以“文件大小正确”
/// 不能单独当作下载完成的依据，必须同时看系统报告的已下载字节数。
Future<bool> _localAiDownloadReadyToVerify(
  LocalAiModel model,
  LocalAiDownloadStatus status,
) async {
  if (status.state == 'successful') return true;
  if (status.total <= 0 || status.received < status.total) return false;
  return _isCompletePartialDownload(model);
}

Future<bool> _isCompletePartialDownload(LocalAiModel model) async {
  try {
    final target = await _downloadedLocalAiModelPath(model);
    final partial = File('$target.partial');
    if (!await partial.exists()) return false;
    return await partial.length() == model.byteSize;
  } on FileSystemException {
    return false;
  }
}

Future<void> _deleteLocalAiModelFiles(LocalAiModel model) async {
  final paths = [
    await _downloadedLocalAiModelPath(model),
    await _legacyLocalAiModelPath(model),
  ];
  for (final path in paths) {
    for (final suffix in ['', '.verified', '.partial']) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
  }
}
