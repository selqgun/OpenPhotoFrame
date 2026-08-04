class SmbSourceConfig {
  const SmbSourceConfig({
    this.host = '',
    this.port = 445,
    this.share = '',
    this.path = '',
    this.username = '',
    this.password = '',
    this.cacheSizeMb = 1024,
  });

  final String host;
  final int port;
  final String share;
  final String path;
  final String username;
  final String password;
  final int cacheSizeMb;

  String get effectiveShare {
    var rawShare = share.trim().replaceAll('\\', '/').trim();
    if (rawShare.startsWith('/')) rawShare = rawShare.substring(1);
    if (rawShare.contains('/')) {
      return rawShare.split('/').first;
    }
    if (rawShare.isNotEmpty) {
      return rawShare;
    }
    var rawPath = path.trim().replaceAll('\\', '/').trim();
    if (rawPath.startsWith('/')) rawPath = rawPath.substring(1);
    if (rawPath.isNotEmpty) {
      return rawPath.split('/').first;
    }
    return '';
  }

  String get effectivePath {
    var rawShare = share.trim().replaceAll('\\', '/').trim();
    if (rawShare.startsWith('/')) rawShare = rawShare.substring(1);
    var extraFromShare = '';
    if (rawShare.contains('/')) {
      final parts = rawShare.split('/');
      extraFromShare = parts.sublist(1).join('/');
    }

    var rawPath = path.trim().replaceAll('\\', '/').trim();
    if (rawPath.startsWith('/')) rawPath = rawPath.substring(1);

    if (share.trim().isEmpty && rawPath.isNotEmpty) {
      final parts = rawPath.split('/');
      return parts.sublist(1).join('/');
    }

    if (extraFromShare.isNotEmpty) {
      if (rawPath.isEmpty) return extraFromShare;
      return '$extraFromShare/$rawPath';
    }

    return normalizedPath;
  }

  bool get isValid => host.trim().isNotEmpty && effectiveShare.isNotEmpty;

  String get normalizedPath {
    var value = path.trim().replaceAll('\\', '/');
    while (value.contains('//')) {
      value = value.replaceAll('//', '/');
    }
    if (value.startsWith('/')) {
      value = value.substring(1);
    }
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Map<String, dynamic> toMap() {
    return {
      'host': host,
      'port': port,
      'share': effectiveShare,
      'path': effectivePath,
      'username': username,
      'password': password,
      'cache_size_mb': cacheSizeMb,
    };
  }

  factory SmbSourceConfig.fromMap(Map<String, dynamic> map) {
    return SmbSourceConfig(
      host: map['host'] as String? ?? '',
      port: (map['port'] as num?)?.toInt() ?? 445,
      share: map['share'] as String? ?? '',
      path: map['path'] as String? ?? '',
      username: map['username'] as String? ?? '',
      password: map['password'] as String? ?? '',
      cacheSizeMb: (map['cache_size_mb'] as num?)?.toInt() ?? 1024,
    );
  }
}
