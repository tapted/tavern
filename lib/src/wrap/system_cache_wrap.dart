library pub.system_cache_wrap;

import 'dart:async';

import '../io.dart';
import '../package.dart';
import '../path_rep.dart';
import '../source_registry.dart';
import '../source/hosted.dart';
import '../source/git.dart';
import '../source.dart';

class SystemCache {
  /// The root directory where this package cache is located.
  final PathRep rootDir;

  PathRep get tempDir => new PathRep('temp');

  /// Packages which are currently being asynchronously downloaded to the cache.
  final Map<PackageId, Future<Package>> _pendingDownloads;

  /// The sources from which to get packages.
  final SourceRegistry sources;

  /// Creates a new package cache which is backed by the given directory on the
  /// user's file system.
  SystemCache(this.rootDir)
      : _pendingDownloads = new Map<PackageId, Future<Package>>(),
        sources = new SourceRegistry() {
  }

  /// Creates a system cache and registers the standard set of sources. If
  /// [isOffline] is `true`, then the offline hosted source will be used.
  /// Defaults to `false`.
  static Future<SystemCache> withSources(PathRep rootDir,
                                         {bool isOffline: false}) {
    var cache = new SystemCache(rootDir);
    cache.register(new HostedSource());
    cache.register(new GitSource());
    cache.sources.setDefault('hosted');
    return Directory.create(rootDir).then((_) => cache);
  }

  /// Registers a new source. This source must not have the same name as a
  /// source that's already been registered.
  void register(Source source) {
    source.bind(this);
    sources.register(source);
  }

  /// Ensures that the package identified by [id] is downloaded to the cache,
  /// loads it, and returns it.
  ///
  /// It is an error to try downloading a package from a source with
  /// `shouldCache == false`.
  Future<Package> download(PackageId id) {
    var source = sources[id.source];

    if (!source.shouldCache) {
      throw new ArgumentError("Package $id is not cacheable.");
    }

    var pending = _pendingDownloads[id];
    if (pending != null) return pending;

    var future = source.downloadToSystemCache(id).whenComplete(() {
      _pendingDownloads.remove(id);
    });

    _pendingDownloads[id] = future;
    return future;
  }

  /// Create a new temporary directory within the system cache. The system
  /// cache maintains its own temporary directory that it uses to stage
  /// packages into while downloading. It uses this instead of the OS's system
  /// temp directory to ensure that it's on the same volume as the pub system
  /// cache so that it can move the directory from it.
  Future<PathRep> createCacheTempDir() =>
    ensureDir(tempDir).then((_) => createTempDir(tempDir, 'dir'));

  /// Deletes the system cache's internal temp directory.
  void deleteCacheTempDir() {
    log.fine('Clean up system cache temp directory $tempDir.');
    deleteEntry(tempDir);
  }
}
