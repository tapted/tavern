library pub.system_cache;

import 'dart:async';

import '../package.dart';
import '../source_registry.dart';

class SystemCache {
  final SourceRegistry sources;

  SystemCache() : sources = new SourceRegistry() {}

  Future<Package> download(PackageId id) {
  }
}
