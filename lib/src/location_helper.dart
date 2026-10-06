part of 'app.dart';

/// 一条带坐标和地址的位置结果。
class LocationResult {
  const LocationResult({
    required this.address,
    required this.latitude,
    required this.longitude,
    this.nearbyPOI,
    this.accuracyMeters,
    this.isApproximate = false,
    this.sourceLabel = '',
  });

  final String address;
  final double latitude;
  final double longitude;
  final String? nearbyPOI;
  final double? accuracyMeters;

  /// 网络大致位置为 true，绝不当作精确位置使用。
  final bool isApproximate;

  /// “卫星定位”“上次定位”“网络大致位置”等，让用户看清来源。
  final String sourceLabel;

  static const empty = LocationResult(address: '', latitude: 0, longitude: 0);

  bool get isEmpty => address.isEmpty && latitude == 0 && longitude == 0;
  bool get isNotEmpty => !isEmpty;
}

enum _LocationAccess { granted, denied, deniedForever, serviceOff, failed }

/// 定位优先使用设备真实位置；拿不到卫星定位时会退回最近一次位置，
/// 并明确标注来源，绝不会把网络位置说成精确定位。
class LocationHelper {
  static const _cacheDuration = Duration(minutes: 3);
  static const _maxLastKnownAge = Duration(minutes: 30);
  static const _goodAccuracyMeters = 60.0;
  static const _instantAccuracyMeters = 30.0;

  static LocationResult? _lastDetailedResult;
  static DateTime? _lastFetchTime;
  static final Map<String, String> _addressCache = {};

  /// 只取地址文本；失败时返回空字符串。
  static Future<String> getCurrentLocation() async {
    final result = await getDetailedLocation();
    return result.address;
  }

  /// 取得位置详情：坐标一定保留，地址解析失败也不会丢掉坐标。
  static Future<LocationResult> getDetailedLocation({
    bool forceRefresh = false,
  }) async {
    final cached = _lastDetailedResult;
    if (!forceRefresh && _isCacheUsable(cached)) return cached!;

    final access = await _ensureAccess();
    if (access != _LocationAccess.granted) {
      debugPrint('[LocationHelper] 定位暂时不可用：${access.name}');
      if (_isCacheUsable(cached)) return cached!;
      return LocationResult.empty;
    }

    var fromLastKnown = false;
    Position? fix;
    if (!forceRefresh) {
      fix = await _lastKnownPosition();
      fromLastKnown = fix != null;
    }
    if (fix == null || fix.accuracy > _goodAccuracyMeters) {
      final live = await _livePosition();
      if (live != null && (fix == null || live.accuracy <= fix.accuracy)) {
        fix = live;
        fromLastKnown = false;
      }
    }
    if (fix == null) {
      if (_isCacheUsable(cached)) return cached!;
      return LocationResult.empty;
    }

    final accuracy = fix.accuracy <= 0 ? null : fix.accuracy.round();
    final area = await _reverseGeocodeCached(fix.latitude, fix.longitude);
    final coordinates =
        '${fix.latitude.toStringAsFixed(5)}, ${fix.longitude.toStringAsFixed(5)}';
    final source = fromLastKnown ? '上次定位' : '卫星定位';
    final accuracyText = accuracy == null ? '精度未知' : '约±$accuracy米';
    final label = area.isEmpty ? coordinates : '$area · $coordinates';
    final result = LocationResult(
      address: '$label（$source，$accuracyText）',
      latitude: fix.latitude,
      longitude: fix.longitude,
      accuracyMeters: accuracy?.toDouble(),
      sourceLabel: source,
    );
    _lastDetailedResult = result;
    _lastFetchTime = DateTime.now();
    return result;
  }

  /// 只有用户明确选择“网络大致位置”时才单独使用。
  static Future<LocationResult> getApproximateLocation() async {
    try {
      final result = await _tryIPGeoLocation().timeout(
        const Duration(seconds: 6),
        onTimeout: () => LocationResult.empty,
      );
      if (result.isNotEmpty) return result;
    } catch (_) {}
    return LocationResult.empty;
  }

  static bool _isCacheUsable(LocationResult? result) {
    if (result == null || result.isEmpty || result.isApproximate) return false;
    final fetchedAt = _lastFetchTime;
    return fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _cacheDuration;
  }

  static Future<_LocationAccess> _ensureAccess() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return _LocationAccess.serviceOff;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return switch (permission) {
        LocationPermission.always ||
        LocationPermission.whileInUse => _LocationAccess.granted,
        LocationPermission.deniedForever => _LocationAccess.deniedForever,
        _ => _LocationAccess.denied,
      };
    } catch (error) {
      debugPrint('[LocationHelper] 权限检查失败：$error');
      return _LocationAccess.failed;
    }
  }

  /// 用最近半小时的历史定位兜底，避免“刚进室内就完全定位不到”。
  static Future<Position?> _lastKnownPosition() async {
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position == null) return null;
      final age = DateTime.now().difference(position.timestamp);
      if (age < Duration.zero || age > _maxLastKnownAge) return null;
      if (position.accuracy <= 0 || position.accuracy > 500) return null;
      return position;
    } catch (error) {
      debugPrint('[LocationHelper] 读取上次位置失败：$error');
      return null;
    }
  }

  /// 订阅定位流，尽快拿到够准的一帧；最慢 18 秒结束，返回期间最好的一帧。
  static Future<Position?> _livePosition() async {
    final completer = Completer<Position?>();
    StreamSubscription<Position>? subscription;
    Timer? timer;
    Position? best;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      timer?.cancel();
      final active = subscription;
      if (active != null) unawaited(active.cancel());
      if (!completer.isCompleted) completer.complete(best);
    }

    try {
      subscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      ).listen(
        (position) {
          if (position.accuracy <= 0) return;
          if (best == null || position.accuracy < best!.accuracy) {
            best = position;
          }
          if (position.accuracy <= _instantAccuracyMeters) finish();
        },
        onError: (Object error) {
          debugPrint('[LocationHelper] 定位流中断：$error');
          finish();
        },
        cancelOnError: true,
      );
      timer = Timer(const Duration(seconds: 18), finish);
    } catch (error) {
      debugPrint('[LocationHelper] 无法开始定位：$error');
      finish();
    }
    return completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        finish();
        return best;
      },
    );
  }

  static Future<String> _reverseGeocodeCached(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';
    final cached = _addressCache[key];
    if (cached != null) return cached;
    var area = '';
    try {
      area = await _tryBigDataCloud(
        lat,
        lon,
      ).timeout(const Duration(seconds: 6), onTimeout: () => '');
    } catch (error) {
      debugPrint('[LocationHelper] 地址解析失败：$error');
    }
    if (area.isNotEmpty) {
      if (_addressCache.length > 120) {
        _addressCache.remove(_addressCache.keys.first);
      }
      _addressCache[key] = area;
    }
    return area;
  }

  /// 网络大致位置，只在“网络定位”模式下使用。
  static Future<LocationResult> _tryIPGeoLocation() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(
        Uri.parse('https://ipwho.is/?lang=zh'),
      );
      request.headers.set('User-Agent', 'ChaoXiLedger/2.0');
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(const Utf8Decoder()).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        if (json['success'] == true) {
          final city = json['city'] as String? ?? '';
          final region = json['region'] as String? ?? '';
          final lat = (json['latitude'] as num?)?.toDouble() ?? 0;
          final lon = (json['longitude'] as num?)?.toDouble() ?? 0;
          final parts = <String>[];
          if (region.isNotEmpty) parts.add(region);
          if (city.isNotEmpty && city != region) parts.add(city);
          final address = parts.join(' ');
          if (address.isNotEmpty && lat != 0 && lon != 0) {
            return LocationResult(
              address: '$address（网络大致位置）',
              latitude: lat,
              longitude: lon,
              isApproximate: true,
              sourceLabel: '网络大致位置',
            );
          }
        }
      }
    } catch (error) {
      debugPrint('[LocationHelper] 网络定位失败：$error');
    } finally {
      client.close();
    }
    return LocationResult.empty;
  }

  /// 附近地点名称暂时留空（国内可用的 POI 服务都需要申请密钥）。
  static Future<String> getNearbyPOI(double lat, double lon) async => '';

  /// 两点之间的直线距离（米）。
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;

  /// 根据地点名称里的关键词猜分类。
  static String? suggestCategoryFromPOI(String poiName) {
    if (poiName.isEmpty) return null;
    final lower = poiName.toLowerCase();
    for (final category in appCategories) {
      if (category.type != EntryType.expense) continue;
      for (final keyword in category.keywords) {
        if (lower.contains(keyword.toLowerCase())) return category.id;
      }
    }
    return null;
  }

  /// 找出附近 200 米内的常用地点。
  static FavoriteLocation? findNearestFavorite(
    double lat,
    double lon,
    List<FavoriteLocation> favorites, {
    double radiusMeters = 200,
  }) {
    FavoriteLocation? nearest;
    var minDist = double.infinity;
    for (final favorite in favorites) {
      final distance = distanceMeters(
        lat,
        lon,
        favorite.latitude,
        favorite.longitude,
      );
      if (distance < radiusMeters && distance < minDist) {
        minDist = distance;
        nearest = favorite;
      }
    }
    return nearest;
  }

  /// 反查中文地址：BigDataCloud 免费、无需密钥，返回简体中文，
  /// 并尽量细到“区 / 街道”一级。
  static Future<String> _tryBigDataCloud(double lat, double lon) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse(
        'https://api.bigdatacloud.net/data/reverse-geocode-client'
        '?latitude=$lat&longitude=$lon&localityLanguage=zh-Hans',
      );
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'ChaoXiLedger/2.1');
      final response = await request.close();
      if (response.statusCode != 200) return '';
      final body = await response.transform(const Utf8Decoder()).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final country = json['countryName'] as String? ?? '';
      final subdivision = json['principalSubdivision'] as String? ?? '';
      final city = json['city'] as String? ?? '';
      final locality = json['locality'] as String? ?? '';
      final parts = <String>[];
      void addPart(String value) {
        final name = value.trim();
        if (name.isEmpty || name == country) return;
        for (final existing in parts) {
          if (existing == name ||
              existing.contains(name) ||
              name.contains(existing)) {
            return;
          }
        }
        parts.add(name);
      }

      addPart(subdivision);
      addPart(city);
      addPart(locality);

      final localityInfo = json['localityInfo'] as Map<String, dynamic>?;
      final administrative = localityInfo?['administrative'] as List<dynamic>?;
      if (administrative != null) {
        final levels = administrative.whereType<Map>().toList()
          ..sort(
            (a, b) => ((a['order'] as int?) ?? 0).compareTo(
              (b['order'] as int?) ?? 0,
            ),
          );
        for (final level in levels) {
          final name = (level['name'] as String?) ?? '';
          if (name.isEmpty) continue;
          // “首都功能核心区”这类规划名称对用户没有帮助。
          if (name.contains('功能区') || name.contains('核心区')) continue;
          addPart(name);
          if (parts.length >= 4) break;
        }
      }

      if (parts.isEmpty && country.isNotEmpty) parts.add(country);
      final result = parts.join('');
      return result.length > 40 ? result.substring(0, 40) : result;
    } finally {
      client.close();
    }
  }
}
