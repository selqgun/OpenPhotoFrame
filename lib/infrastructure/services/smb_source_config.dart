class SmbSourceConfig {
  const SmbSourceConfig({
    this.host = '',
    this.port = 445,
    this.share = '',
    this.path = '',
    this.username = '',
    this.password = '',
    this.domain = '',
    this.anonymous = false,
    this.cacheSizeMb = 1024,
  });

  final String host;
  final int port;
  final String share;
  final String path;
  final String username;
  final String password;
  final String domain;
  final bool anonymous;
  final int cacheSizeMb;

  bool get isValid => host.trim().isNotEmpty && share.trim().isNotEmpty;

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
      'share': share,
      'path': normalizedPath,
      'username': username,
      'password': password,
      'domain': domain,
      'anonymous': anonymous,
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
      domain: map['domain'] as String? ?? '',
      anonymous: map['anonymous'] as bool? ?? false,
      cacheSizeMb: (map['cache_size_mb'] as num?)?.toInt() ?? 1024,
    );
  }
}
