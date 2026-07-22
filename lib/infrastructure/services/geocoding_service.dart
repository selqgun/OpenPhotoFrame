import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum GeocodingProvider { amap, nominatim }

class GeocodingResult {
  final String? locationName;
  final String? error;

  const GeocodingResult({this.locationName, this.error});

  bool get hasLocationName => locationName != null && locationName!.isNotEmpty;
}

extension on GeocodingProvider {
  String get configValue {
    switch (this) {
      case GeocodingProvider.amap:
        return 'amap';
      case GeocodingProvider.nominatim:
        return 'nominatim';
    }
  }
}

/// Service for reverse geocoding (coordinates → place name)
/// Uses OpenStreetMap Nominatim API (free, no API key required)
/// Caches results persistently with automatic cleanup of old entries.
class GeocodingService {
  final _log = Logger('GeocodingService');
  
  // In-memory cache: "lat,lon" → location name
  final Map<String, String?> _cache = {};
  
  // Timestamps for cache entries (for cleanup)
  final Map<String, DateTime> _cacheTimestamps = {};
  
  /// User-Agent required by Nominatim usage policy
  static const String _userAgent = 'OpenPhotoFrame/1.0';
  
  /// Prefix for SharedPreferences keys
  static const String _prefsPrefix = 'geocache_';
  static const String _prefsTsPrefix = 'geocache_ts_';
  
  /// Maximum age for cache entries (3 months)
  static const Duration _maxCacheAge = Duration(days: 90);
  
  bool _initialized = false;

  String get _preferredLanguageHeader {
    final locale = Platform.localeName;
    final normalized = locale.split('.').first.replaceAll('_', '-');
    if (normalized.isEmpty) {
      return 'zh-CN,zh,en';
    }
    return '$normalized,zh-CN,zh,en';
  }
  
  /// Initialize the service and load persistent cache
  Future<void> initialize() async {
    if (_initialized) return;
    
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefsPrefix) && !k.startsWith(_prefsTsPrefix));
    
    final now = DateTime.now();
    int loaded = 0;
    int expired = 0;
    
    for (final key in keys) {
      final cacheKey = key.substring(_prefsPrefix.length);
      final tsKey = '$_prefsTsPrefix$cacheKey';
      
      // Check timestamp
      final tsMillis = prefs.getInt(tsKey);
      if (tsMillis != null) {
        final timestamp = DateTime.fromMillisecondsSinceEpoch(tsMillis);
        if (now.difference(timestamp) > _maxCacheAge) {
          // Entry expired - remove it
          await prefs.remove(key);
          await prefs.remove(tsKey);
          expired++;
          continue;
        }
        _cacheTimestamps[cacheKey] = timestamp;
      }
      
      final value = prefs.getString(key);
      _cache[cacheKey] = value; // null if stored as empty
      loaded++;
    }
    
    _initialized = true;
    _log.info('Geocoding cache loaded: $loaded entries, $expired expired entries removed');
  }
  
  /// Reverse geocode coordinates to a place name.
  /// Returns a structured result so callers can distinguish failures from empty results.
  Future<GeocodingResult> getLocationName(
    double latitude,
    double longitude, {
    GeocodingProvider provider = GeocodingProvider.amap,
    String apiKey = '',
  }) async {
    // Ensure initialized
    if (!_initialized) await initialize();
    
    // Round to 3 decimal places (~100m precision) for caching
    final cacheKey = '${provider.configValue}:${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}';
    
    // Check cache first
    if (_cache.containsKey(cacheKey)) {
      return GeocodingResult(locationName: _cache[cacheKey]);
    }
    
    try {
      if (provider == GeocodingProvider.amap) {
        return _reverseGeocodeWithAmap(latitude, longitude, cacheKey, apiKey);
      }
      return _reverseGeocodeWithNominatim(latitude, longitude, cacheKey);
      
    } catch (e) {
      final error = 'Geocoding error: $e';
      _log.warning('Geocoding error for ($latitude, $longitude): $e');
      // Don't cache network errors - might be temporary
      return GeocodingResult(error: error);
    }
  }

  Future<GeocodingResult> _reverseGeocodeWithAmap(
    double latitude,
    double longitude,
    String cacheKey,
    String apiKey,
  ) async {
    if (apiKey.trim().isEmpty) {
      return const GeocodingResult(error: 'AMap API key is not configured');
    }

    final url = Uri.parse(
      'https://restapi.amap.com/v3/geocode/regeo'
      '?key=$apiKey'
      '&location=$longitude,$latitude'
      '&language=zh_cn'
      '&extensions=base'
      '&radius=1000'
      '&roadlevel=0',
    );

    final response = await http.get(url, headers: {
      'User-Agent': _userAgent,
    }).timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      final error = 'AMap geocoding failed: HTTP ${response.statusCode}';
      _log.warning(error);
      return GeocodingResult(error: error);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final status = json['status']?.toString();
    if (status != '1') {
      final info = json['info']?.toString() ?? 'unknown error';
      return GeocodingResult(error: 'AMap geocoding failed: $info');
    }

    final regeocode = json['regeocode'] as Map<String, dynamic>?;
    final addressComponent = regeocode?['addressComponent'] as Map<String, dynamic>?;
    if (addressComponent == null) {
      await _cacheResult(cacheKey, null);
      return const GeocodingResult();
    }

    final parts = <String>[];
    final district = addressComponent['district'];
    final city = addressComponent['city'];
    final province = addressComponent['province'];

    if (district != null && district.toString().isNotEmpty) {
      parts.add(district.toString());
    }
    if (city != null && city.toString().isNotEmpty) {
      final cityValue = city.toString();
      if (!parts.contains(cityValue)) {
        parts.add(cityValue);
      }
    }
    if (province != null && province.toString().isNotEmpty) {
      final provinceValue = province.toString();
      if (!parts.contains(provinceValue)) {
        parts.add(provinceValue);
      }
    }

    final result = parts.isNotEmpty ? parts.join(', ') : null;
    await _cacheResult(cacheKey, result);
    _log.fine('AMap geocoded ($latitude, $longitude) -> $result');
    return GeocodingResult(locationName: result);
  }

  Future<GeocodingResult> _reverseGeocodeWithNominatim(
    double latitude,
    double longitude,
    String cacheKey,
  ) async {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse'
      '?lat=$latitude'
      '&lon=$longitude'
      '&format=json'
      '&zoom=10'
      '&addressdetails=1',
    );

    final response = await http.get(url, headers: {
      'User-Agent': _userAgent,
      'Accept-Language': _preferredLanguageHeader,
    }).timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      final error = 'Geocoding failed: HTTP ${response.statusCode}';
      _log.warning(error);
      return GeocodingResult(error: error);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final address = json['address'] as Map<String, dynamic>?;

    if (address == null) {
      await _cacheResult(cacheKey, null);
      return const GeocodingResult();
    }

    final parts = <String>[];
    final city = address['city'] ??
        address['town'] ??
        address['village'] ??
        address['municipality'] ??
        address['county'];
    if (city != null) parts.add(city.toString());

    final state = address['state'];
    if (state != null) parts.add(state.toString());

    final country = address['country'];
    if (country != null) parts.add(country.toString());

    final result = parts.isNotEmpty ? parts.join(', ') : null;
    await _cacheResult(cacheKey, result);

    _log.fine('Geocoded ($latitude, $longitude) -> $result');
    return GeocodingResult(locationName: result);
  }
  
  /// Cache a result both in memory and persistently
  Future<void> _cacheResult(String cacheKey, String? result) async {
    _cache[cacheKey] = result;
    _cacheTimestamps[cacheKey] = DateTime.now();
    
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefsPrefix$cacheKey';
    final tsKey = '$_prefsTsPrefix$cacheKey';
    
    if (result != null) {
      await prefs.setString(key, result);
    } else {
      await prefs.setString(key, ''); // Store empty string for null results
    }
    await prefs.setInt(tsKey, DateTime.now().millisecondsSinceEpoch);
  }
  
  /// Remove cache entries for coordinates that are no longer used
  /// Call this with a set of still-valid coordinates to clean up orphans
  Future<void> cleanupOrphans(Set<String> validCoordinates) async {
    final prefs = await SharedPreferences.getInstance();
    final keysToRemove = <String>[];
    
    for (final cacheKey in _cache.keys.toList()) {
      if (!validCoordinates.contains(cacheKey)) {
        keysToRemove.add(cacheKey);
      }
    }
    
    for (final cacheKey in keysToRemove) {
      _cache.remove(cacheKey);
      _cacheTimestamps.remove(cacheKey);
      await prefs.remove('$_prefsPrefix$cacheKey');
      await prefs.remove('$_prefsTsPrefix$cacheKey');
    }
    
    if (keysToRemove.isNotEmpty) {
      _log.info('Geocoding cache cleanup: removed ${keysToRemove.length} orphaned entries');
    }
  }
  
  /// Clear the entire geocoding cache
  Future<void> clearCache() async {
    _cache.clear();
    _cacheTimestamps.clear();
    
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(
      (k) => k.startsWith(_prefsPrefix) || k.startsWith(_prefsTsPrefix)
    ).toList();
    
    for (final key in keys) {
      await prefs.remove(key);
    }
    
    _log.info('Geocoding cache cleared');
  }
}
