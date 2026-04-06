part of 'app.dart';

/// Lightweight location helper that works in China.
/// Uses Android native GPS (via geolocator with forceAndroidLocationManager)
/// and OpenStreetMap Nominatim for reverse geocoding (no Google dependency).
class LocationHelper {
  static String _lastAddress = '';
  static DateTime? _lastFetchTime;

  /// How long to cache between location fetches (avoid battery drain).
  static const _cacheDuration = Duration(minutes: 2);

  /// Get a human-readable location string.
  /// Returns empty string if location is unavailable.
  static Future<String> getCurrentLocation() async {
    // Use cache if fresh enough
    if (_lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _cacheDuration &&
        _lastAddress.isNotEmpty) {
      return _lastAddress;
    }

    try {
      // Check permission
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return '';
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return '';
      }

      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return '';

      // Get position using Android native LocationManager (NOT Google)
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 5),
        ),
      );

      // Reverse geocode via OpenStreetMap Nominatim (works in China, free)
      final address = await _reverseGeocodeOSM(position.latitude, position.longitude);
      if (address.isNotEmpty) {
        _lastAddress = address;
        _lastFetchTime = DateTime.now();
      }
      return _lastAddress;
    } catch (_) {
      return _lastAddress;
    }
  }

  /// Reverse geocode using OpenStreetMap Nominatim API.
  /// Free, works globally including China, requires no API key.
  static Future<String> _reverseGeocodeOSM(double lat, double lon) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&accept-language=zh-CN&zoom=16',
      );
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'ChaoXiLedger/2.0');
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(const Utf8Decoder()).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final addressObj = json['address'] as Map<String, dynamic>?;

        if (addressObj != null) {
          final parts = <String>[];
          final district = addressObj['suburb'] ?? addressObj['district'] ?? addressObj['city_district'] ?? '';
          final road = addressObj['road'] ?? '';
          final neighbourhood = addressObj['neighbourhood'] ?? '';
          final city = addressObj['city'] ?? addressObj['town'] ?? addressObj['county'] ?? '';

          if (city.toString().isNotEmpty) parts.add(city.toString());
          if (district.toString().isNotEmpty && district != city) parts.add(district.toString());
          if (road.toString().isNotEmpty) parts.add(road.toString());
          if (neighbourhood.toString().isNotEmpty && parts.length < 3) parts.add(neighbourhood.toString());

          final result = parts.join(' ');
          return result.length > 30 ? result.substring(0, 30) : result;
        }

        // Fallback: use display_name
        final displayName = json['display_name'] as String?;
        if (displayName != null && displayName.isNotEmpty) {
          final segments = displayName.split(',').map((s) => s.trim()).toList();
          final short = segments.take(3).join(' ');
          return short.length > 30 ? short.substring(0, 30) : short;
        }
      }
    } catch (_) {
      // Network or parse error - silently fail
    } finally {
      client.close();
    }
    return '';
  }
}
