part of 'app.dart';

/// Structured location result with address text and coordinates.
class LocationResult {
  const LocationResult({
    required this.address,
    required this.latitude,
    required this.longitude,
    this.nearbyPOI,
  });

  final String address;
  final double latitude;
  final double longitude;
  final String? nearbyPOI;

  static const empty = LocationResult(address: '', latitude: 0, longitude: 0);

  bool get isEmpty => address.isEmpty && latitude == 0 && longitude == 0;
  bool get isNotEmpty => !isEmpty;
}

/// Lightweight location helper that works in China.
/// Uses Android native GPS (via geolocator with forceAndroidLocationManager)
/// and OpenStreetMap Nominatim for reverse geocoding (no Google dependency).
class LocationHelper {
  static String _lastAddress = '';
  static DateTime? _lastFetchTime;
  static LocationResult? _lastDetailedResult;

  /// How long to cache between location fetches (avoid battery drain).
  static const _cacheDuration = Duration(minutes: 2);

  /// Get a human-readable location string.
  /// Returns empty string if location is unavailable.
  static Future<String> getCurrentLocation() async {
    final result = await getDetailedLocation();
    return result.address;
  }

  /// Get full location details including coordinates.
  /// Returns LocationResult.empty if unavailable.
  static Future<LocationResult> getDetailedLocation() async {
    // Use cache if fresh enough
    if (_lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _cacheDuration &&
        _lastDetailedResult != null &&
        _lastDetailedResult!.isNotEmpty) {
      debugPrint('[LocationHelper] Using cached result');
      return _lastDetailedResult!;
    }

    try {
      // Check GPS permission
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          // GPS denied → use IP geolocation only
          return await _ipFallback();
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return await _ipFallback();
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      debugPrint('[LocationHelper] Getting position...');

      // Step 1: Try lastKnownPosition (instant)
      Position? position;
      if (serviceEnabled) {
        position = await Geolocator.getLastKnownPosition();
        debugPrint('[LocationHelper] lastKnown: $position');
      }

      // Step 2: If no cached GPS, race between fresh GPS and IP geolocation
      if (position == null) {
        debugPrint('[LocationHelper] No lastKnown, racing GPS vs IP...');
        final futures = <Future<LocationResult>>[];

        // GPS fresh position
        if (serviceEnabled) {
          futures.add(
            Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                timeLimit: Duration(seconds: 5),
              ),
            ).then((pos) async {
              final addr = await _tryBigDataCloud(pos.latitude, pos.longitude)
                  .timeout(const Duration(seconds: 5), onTimeout: () => '');
              return LocationResult(
                address: addr.isNotEmpty ? addr : '${pos.latitude.toStringAsFixed(4)}°N, ${pos.longitude.toStringAsFixed(4)}°E',
                latitude: pos.latitude,
                longitude: pos.longitude,
              );
            }),
          );
        }

        // IP geolocation (fast, ~1s)
        futures.add(
          _tryIPGeoLocation().timeout(
            const Duration(seconds: 4),
            onTimeout: () => LocationResult.empty,
          ),
        );

        if (futures.isNotEmpty) {
          try {
            final result = await Future.any<LocationResult>(
              futures.map((f) => f.then<LocationResult>((r) => r.isNotEmpty ? r : Future<LocationResult>.error('empty'))).toList(),
            ).timeout(const Duration(seconds: 8), onTimeout: () => LocationResult.empty);

            if (result.isNotEmpty) {
              _lastAddress = result.address;
              _lastDetailedResult = result;
              _lastFetchTime = DateTime.now();
              // Background: upgrade GPS for next call
              if (serviceEnabled) {
                Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.high,
                    timeLimit: Duration(seconds: 5),
                  ),
                ).then((f) {
                  _lastDetailedResult = LocationResult(
                    address: _lastAddress,
                    latitude: f.latitude,
                    longitude: f.longitude,
                  );
                }).catchError((_) {});
              }
              return result;
            }
          } catch (_) {}
        }
        return LocationResult.empty;
      }

      // Step 3: Have GPS position → geocode with BigDataCloud
      debugPrint('[LocationHelper] Got position: ${position.latitude}, ${position.longitude}');

      // Background: upgrade GPS for next call
      if (serviceEnabled) {
        Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        ).then((fresh) {
          _lastDetailedResult = LocationResult(
            address: _lastAddress,
            latitude: fresh.latitude,
            longitude: fresh.longitude,
          );
        }).catchError((_) {});
      }

      // Reverse geocode
      String address = '';
      try {
        address = await _tryBigDataCloud(position.latitude, position.longitude)
            .timeout(const Duration(seconds: 6), onTimeout: () => '');
      } catch (_) {
        debugPrint('[LocationHelper] Geocode failed');
      }

      if (address.isEmpty) {
        address = '${position.latitude.toStringAsFixed(4)}°N, ${position.longitude.toStringAsFixed(4)}°E';
      }

      final result = LocationResult(
        address: address,
        latitude: position.latitude,
        longitude: position.longitude,
      );

      _lastAddress = address;
      _lastDetailedResult = result;
      _lastFetchTime = DateTime.now();
      return result;
    } catch (e) {
      debugPrint('[LocationHelper] Unexpected error: $e');
      return _lastDetailedResult ?? LocationResult.empty;
    }
  }

  /// IP-based geolocation fallback (when GPS is fully unavailable).
  static Future<LocationResult> _ipFallback() async {
    try {
      final result = await _tryIPGeoLocation()
          .timeout(const Duration(seconds: 5), onTimeout: () => LocationResult.empty);
      if (result.isNotEmpty) {
        _lastDetailedResult = result;
        _lastAddress = result.address;
        _lastFetchTime = DateTime.now();
        return result;
      }
    } catch (_) {}
    return LocationResult.empty;
  }

  /// IP geolocation via ip-api.com (free, no key, max 45 req/min).
  /// Returns Chinese address + approximate coordinates.
  static Future<LocationResult> _tryIPGeoLocation() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse('http://ip-api.com/json/?lang=zh-CN&fields=status,city,regionName,lat,lon');
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'ChaoXiLedger/2.0');
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(const Utf8Decoder()).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        if (json['status'] == 'success') {
          final city = json['city'] as String? ?? '';
          final region = json['regionName'] as String? ?? '';
          final lat = (json['lat'] as num?)?.toDouble() ?? 0;
          final lon = (json['lon'] as num?)?.toDouble() ?? 0;

          final parts = <String>[];
          if (region.isNotEmpty) parts.add(region);
          if (city.isNotEmpty && city != region) parts.add(city);
          final address = parts.join(' ');

          if (address.isNotEmpty && lat != 0 && lon != 0) {
            debugPrint('[LocationHelper] IP geolocation: $address ($lat, $lon)');
            return LocationResult(address: address, latitude: lat, longitude: lon);
          }
        }
      }
    } catch (e) {
      debugPrint('[LocationHelper] IP geolocation failed: $e');
    } finally {
      client.close();
    }
    return LocationResult.empty;
  }

  /// Reverse geocode — BigDataCloud only (fast, free, no key, China-friendly).
  static Future<String> _reverseGeocodeOSM(double lat, double lon) async {
    try {
      return await _tryBigDataCloud(lat, lon)
          .timeout(const Duration(seconds: 6), onTimeout: () => '');
    } catch (_) {
      return '';
    }
  }

  /// Query nearby POI name.
  /// Note: Nominatim is blocked in China, so this returns empty for now.
  /// Could be replaced with a China-friendly POI API in the future.
  static Future<String> getNearbyPOI(double lat, double lon) async {
    // Skip POI lookup to avoid blocking (Nominatim not reachable in China)
    return '';
  }

  /// Calculate distance between two coordinates in meters.
  /// Uses Haversine formula for accuracy.
  static double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0; // meters
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) * math.cos(_toRadians(lat2)) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;

  /// Try to suggest a category based on nearby POI keywords.
  /// Returns matching categoryId or null.
  static String? suggestCategoryFromPOI(String poiName) {
    if (poiName.isEmpty) return null;
    final lower = poiName.toLowerCase();
    for (final category in appCategories) {
      if (category.type != EntryType.expense) continue;
      for (final keyword in category.keywords) {
        if (lower.contains(keyword.toLowerCase())) {
          return category.id;
        }
      }
    }
    return null;
  }

  /// Find the nearest FavoriteLocation within a radius (default 200m).
  /// Returns null if nothing is nearby.
  static FavoriteLocation? findNearestFavorite(
    double lat, double lon,
    List<FavoriteLocation> favorites, {
    double radiusMeters = 200,
  }) {
    FavoriteLocation? nearest;
    double minDist = double.infinity;
    for (final fav in favorites) {
      final dist = distanceMeters(lat, lon, fav.latitude, fav.longitude);
      if (dist < radiusMeters && dist < minDist) {
        minDist = dist;
        nearest = fav;
      }
    }
    return nearest;
  }


  /// BigDataCloud reverse geocoding (free, no API key, works in China).
  /// https://www.bigdatacloud.com/free-api/free-reverse-geocode-to-city-api
  static Future<String> _tryBigDataCloud(double lat, double lon) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse(
        'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=$lat&longitude=$lon&localityLanguage=zh',
      );
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'ChaoXiLedger/2.0');
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(const Utf8Decoder()).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        final parts = <String>[];

        // Try city
        final city = json['city'] as String? ?? '';
        if (city.isNotEmpty) parts.add(city);

        // Try locality
        final locality = json['locality'] as String? ?? '';
        if (locality.isNotEmpty && locality != city) parts.add(locality);

        // Try principalSubdivision (province/state)
        if (parts.isEmpty) {
          final subdivision = json['principalSubdivision'] as String? ?? '';
          if (subdivision.isNotEmpty) parts.add(subdivision);
        }

        // Try localityInfo for more detail
        final localityInfo = json['localityInfo'] as Map<String, dynamic>?;
        if (localityInfo != null) {
          final adminLevels = localityInfo['administrative'] as List<dynamic>?;
          if (adminLevels != null && parts.length < 2) {
            // Get district-level info (higher order = more specific)
            final sorted = [...adminLevels]
              ..sort((a, b) => ((b as Map)['order'] as int? ?? 0)
                  .compareTo((a as Map)['order'] as int? ?? 0));
            for (final level in sorted) {
              final name = (level as Map)['name'] as String? ?? '';
              if (name.isNotEmpty && !parts.contains(name)) {
                parts.add(name);
                if (parts.length >= 3) break;
              }
            }
          }
        }

        if (parts.isNotEmpty) {
          final result = parts.join(' ');
          debugPrint('[LocationHelper] BigDataCloud result: $result');
          return result.length > 30 ? result.substring(0, 30) : result;
        }

        // Last resort: countryName
        final country = json['countryName'] as String? ?? '';
        if (country.isNotEmpty) return country;
      }
    } catch (_) {
      rethrow;
    } finally {
      client.close();
    }
    return '';
  }
}
