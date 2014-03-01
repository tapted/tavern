// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub.entrypoint;

import 'dart:async';

import 'package:path/path.dart' as path;

import 'io.dart';
import 'git.dart' as git;
import 'lock_file.dart';
import 'log.dart' as log;
import 'package.dart';
import 'package_graph.dart';
import 'path_rep.dart';
import 'solver/version_solver.dart';
import 'utils.dart';
import 'wrap/system_cache_wrap.dart';

/// Pub operates over a directed graph of dependencies that starts at a root
/// "entrypoint" package. This is typically the package where the current
/// working directory is located. An entrypoint knows the [root] package it is
/// associated with and is responsible for managing the "packages" directory
/// for it.
///
/// That directory contains symlinks to all packages used by an app. These links
/// point either to the [SystemCache] or to some other location on the local
/// filesystem.
///
/// While entrypoints are typically applications, a pure library package may end
/// up being used as an entrypoint. Also, a single package may be used as an
/// entrypoint in one context but not in another. For example, a package that
/// contains a reusable library may not be the entrypoint when used by an app,
/// but may be the entrypoint when you're running its tests.
class Entrypoint {
  /// The root package this entrypoint is associated with.
  Package root;

  /// The system-wide cache which caches packages that need to be fetched over
  /// the network.
  final SystemCache cache;

  /// A map of the [Future]s that were or are being used to asynchronously get
  /// packages.
  ///
  /// Includes packages that are in-transit and ones that have already
  /// completed.
  final _pendingGets = new Map<PackageId, Future<PackageId>>();

  /// Create an entrypoint from a system cache and a package.
  Entrypoint(SystemCache this.cache, Package this.root);

  /// Loads the entrypoint from a package at [rootDir].
  static Future<Entrypoint> load(PathRep rootDir, SystemCache cache) {
    return Package.load(null, rootDir, cache.sources)
        .then((package) => new Entrypoint(cache, package));
  }

  // TODO(rnystrom): Make this path configurable.
  /// The path to the entrypoint's "packages" directory.
  PathRep get packagesDir => root.dir.join('packages');

  /// `true` if the entrypoint package currently has a lock file.
  Future<bool> get lockFileExists => entryExists(lockFilePath);

  /// The path to the entrypoint package's lockfile.
  PathRep get lockFilePath => root.dir.join('pubspec.lock');

  /// Gets package [id] and makes it available for use by this entrypoint.
  ///
  /// If this completes successfully, the package is guaranteed to be importable
  /// using the `package:` scheme. Returns the resolved [PackageId].
  ///
  /// This automatically downloads the package to the system-wide cache as well
  /// if it requires network access to retrieve (specifically, if the package's
  /// source has [shouldCache] as `true`).
  ///
  /// See also [getDependencies].
  Future<PackageId> get(PackageId id) {
    if (_pendingGets[id] != null) return _pendingGets[id];

    var source;
    var packageDir = packagesDir.join(id.name);

    // TODO(nweiz): figure out when to actually delete the directory, and
    // when we can just re-use the existing symlink.
    log.fine("Ensuring no package directory exists for ${id.name} before get.");
    var future = deleteEntry(packageDir).then((_) {
      source = cache.sources[id.source];

      if (source.shouldCache) {
        return cache.download(id).then((pkg) {
          return createPackageSymlink(id.name, pkg.dir, packageDir);
        });
      } else {
        return source.get(id, packageDir).then((found) {
          if (found) return null;
          fail('Package ${id.name} not found in source "${id.source}".');
        });
      }
    }).then((_) => source.resolveId(id));

    _pendingGets[id] = future;

    return future;
  }

  /// Gets all dependencies of the [root] package.
  ///
  /// [useLatest], if provided, defines a list of packages that will be
  /// unlocked and forced to their latest versions. If [upgradeAll] is
  /// true, the previous lockfile is ignored and all packages are re-resolved
  /// from scratch. Otherwise, it will attempt to preserve the versions of all
  /// previously locked packages.
  ///
  /// If [useLatest] is non-empty or [upgradeAll] is true, displays a detailed
  /// report of the changes made relative to the previous lockfile.
  ///
  /// Returns a [Future] that completes to the number of changed dependencies.
  /// It completes when an up-to-date lockfile has been generated and all
  /// dependencies are available.
  Future<int> acquireDependencies({List<String> useLatest,
                                   bool upgradeAll: false}) {
    var numChanged = 0;
    var result;

    return loadLockFile().then((lockFile) {
      return resolveVersions(cache.sources,
                             root,
                             lockFile: lockFile,
                             useLatest: useLatest,
                             upgradeAll: upgradeAll);
    }).then((r) {
      result = r;
      if (!result.succeeded) throw result.error;

      // TODO(rnystrom): Should also show the report if there were changes.
      // That way pub get/build/serve will show the report when relevant.
      // https://code.google.com/p/dart/issues/detail?id=15587
      numChanged = result.showReport(
          showAll: useLatest != null || upgradeAll);

      // Install the packages.
      return cleanDir(packagesDir);
    }).then((_) {
      return Future.wait(result.packages.map((id) {
        if (id.isRoot) return new Future.value(id);
        return get(id);
      }).toList());
    }).then((ids) => _saveLockFile(ids))
    .then((_) => _linkSelf())
    //.then((_) => _linkSecondaryPackageDirs())
    .then((_) => numChanged);
  }

  /// Loads the list of concrete package versions from the `pubspec.lock`, if it
  /// exists. If it doesn't, this completes to an empty [LockFile].
  Future<LockFile> loadLockFile() {
    return lockFileExists.then((exists) {
      if (!exists) return new LockFile.empty();
      return LockFile.load(lockFilePath, cache.sources);
    });
  }

  /// Determines whether or not the lockfile is out of date with respect to the
  /// pubspec.
  ///
  /// This will be `false` if there is no lockfile at all, or if the pubspec
  /// contains dependencies that are not in the lockfile or that don't match
  /// what's in there.
  bool _isLockFileUpToDate(LockFile lockFile) {
    return root.immediateDependencies.every((package) {
      var locked = lockFile.packages[package.name];
      if (locked == null) return false;

      if (package.source != locked.source) return false;
      if (!package.constraint.allows(locked.version)) return false;

      var source = cache.sources[package.source];
      if (source == null) return false;

      return source.descriptionsEqual(package.description, locked.description);
    });
  }

  /// Determines whether all of the packages in the lockfile are already
  /// installed and available.
  ///
  /// Note: this assumes [isLockFileUpToDate] has already been called and
  /// returned `true`.
  Future<bool> _arePackagesAvailable(LockFile lockFile) {
    return Future.wait(lockFile.packages.values.map((package) {
      var source = cache.sources[package.source];

      // This should only be called after [_isLockFileUpToDate] has returned
      // `true`, which ensures all of the sources in the lock file are valid.
      assert(source != null);

      // We only care about cached sources. Uncached sources aren't "installed".
      // If one of those is missing, we want to show the user the file not
      // found error later since installing won't accomplish anything.
      if (!source.shouldCache) return new Future.value(true);

      // Get the directory.
      return source.getDirectory(package).then((dir) {
        // See if the directory is there and looks like a package.
        return fileExists(dir.join("pubspec.yaml"));
      });
    })).then((results) {
      // Make sure they are all true.
      return results.every((result) => result);
    });
  }

  /// Gets dependencies if the lockfile is out of date with respect to the
  /// pubspec.
  Future ensureLockFileIsUpToDate() {
    return new Future.sync(() {
      var lockFile = loadLockFile();

      // If we don't have a current lock file, we definitely need to install.
      if (!_isLockFileUpToDate(lockFile)) {
        return lockFileExists.then((exists) {
          log.message(exists ?
              "Your pubspec has changed, so we need to update your lockfile:" :
              "You don't have a lockfile, so we need to generate that:");
          return false;
        });
      }

      // If we do have a lock file, we still need to make sure the packages
      // are actually installed. The user may have just gotten a package that
      // includes a lockfile.
      return _arePackagesAvailable(lockFile).then((available) {
        if (!available) {
          log.message(
              "You are missing some dependencies, so we need to install them "
              "first:");
        }

        return available;
      });
    }).then((upToDate) {
      if (upToDate) return null;
      return acquireDependencies().then((_) {
        log.message("Got dependencies!");
      });
    });
  }

  /// Loads the package graph for the application and all of its transitive
  /// dependencies.
  Future<PackageGraph> loadPackageGraph() {
    var lockFile = loadLockFile();
    return Future.wait(lockFile.packages.values.map((id) {
      var source = cache.sources[id.source];
      return source.getDirectory(id)
          .then((dir) => Package.load(id.name, dir, cache.sources));
    })).then((packages) {
      var packageMap = <String, Package>{};
      for (var package in packages) {
        packageMap[package.name] = package;
      }
      packageMap[root.name] = root;
      return new PackageGraph(this, lockFile, packageMap);
    });
  }

  /// Saves a list of concrete package versions to the `pubspec.lock` file.
  Future _saveLockFile(List<PackageId> packageIds) {
    var lockFile = new LockFile.empty();
    for (var id in packageIds) {
      if (!id.isRoot) lockFile.packages[id.name] = id;
    }

    var lockFilePath = root.dir.join('pubspec.lock');
    return writeTextFile(lockFilePath,
                         lockFile.serialize(root.dir, cache.sources));
  }

  /// Creates a self-referential symlink in the `packages` directory that allows
  /// a package to import its own files using `package:`.
  Future _linkSelf() {
    var linkPath = packagesDir.join(root.name);
    // Create the symlink if it doesn't exist.
    return entryExists(linkPath).then((exists) {
      if (exists) return new Future.value();

      return ensureDir(packagesDir).then((_) {
        return createPackageSymlink(root.name, root.dir, linkPath,
                                    isSelfLink: true, relative: true);
      });
    });
  }

  /// Add "packages" directories to the whitelist of directories that may
  /// contain Dart entrypoints.
  Future _linkSecondaryPackageDirs() {
    // Only the main "bin" directory gets a "packages" directory, not its
    // subdirectories.
    var binDir = root.dir.join('bin');

    return dirExists(binDir).then((exists) {
      return new Future.sync(() {
        if (exists)
          _linkSecondaryPackageDir(binDir);
      }).then((_) {
        // The others get "packages" directories in subdirectories too.
        var dirs = ['benchmark', 'example', 'test', 'tool', 'web'].map(
            (dir) => root.dir.join(dir));

        return Future.forEach(dirs, _linkSecondaryPackageDirsRecursively);
      });
    });
 }

  /// Creates a symlink to the `packages` directory in [dir] and all its
  /// subdirectories.
  Future _linkSecondaryPackageDirsRecursively(PathRep dir) {
    return dirExists(dir).then((exists) {
      if (!exists) return new Future.value();

      return _linkSecondaryPackageDir(dir)
          .then((_) => _listDirWithoutPackages(dir))
          .then((Iterable<PathRep> files) {
            return Future.forEach(
                files.where((file) => file.isDirectory),
                _linkSecondaryPackageDir);
          });
    });
  }

  // TODO(nweiz): roll this into [listDir] in io.dart once issue 4775 is fixed.
  /// Recursively lists the contents of [dir], excluding hidden `.DS_Store`
  /// files and `package` files.
  Future<List<PathRep>> _listDirWithoutPackages(dir) {
    return Directory.load(dir)
        .then((dir) => dir.list())
        .then((fileEntries) {
          return fileEntries.map((entry) => entry.path)
            .where((path) => !path.inPackages());
        });
  }

  /// Creates a symlink to the `packages` directory in [dir]. Will replace one
  /// if already there.
  Future _linkSecondaryPackageDir(PathRep dir) {
    var symlink = dir.join('packages');

    return deleteEntry(symlink).then((_) =>
        createSymlink(packagesDir, symlink, relative: true));
  }

  /// The basenames of files that are automatically excluded from archives.
  final _BLACKLISTED_FILES = const ['pubspec.lock'];

  /// The basenames of directories that are automatically excluded from
  /// archives.
  final _BLACKLISTED_DIRS = const ['packages'];

  // TODO(nweiz): unit test this function.
  /// Returns a list of files that are considered to be part of this package.
  ///
  /// If this is a Git repository, this will respect .gitignore; otherwise, it
  /// will return all non-hidden, non-blacklisted files.
  ///
  /// If [beneath] is passed, this will only return files beneath that path.
  Future<List<String>> packageFiles({String beneath}) {
    if (beneath == null) beneath = root.dir;

    return git.isInstalled.then((gitInstalled) {
      if (dirExists(root.dir.join('.git')) && gitInstalled) {
        // Later versions of git do not allow a path for ls-files that appears
        // to be outside of the repo, so make sure we give it a relative path.
        var relativeBeneath = path.relative(beneath, from: root.dir);

        // List all files that aren't gitignored, including those not checked
        // in to Git.
        return git.run(
            ["ls-files", "--cached", "--others", "--exclude-standard",
             relativeBeneath],
            workingDir: root.dir).then((files) {
          // Git always prints files relative to the project root, but we want
          // them relative to the working directory. It also prints forward
          // slashes on Windows which we normalize away for easier testing.
          return files.map((file) => path.normalize(path.join(root.dir, file)));
        });
      }

      return listDir(beneath, recursive: true);
    }).then((files) {
      return files.where((file) {
        // Skip directories and broken symlinks.
        if (!fileExists(file)) return false;

        var relative = path.relative(file, from: beneath);
        if (_BLACKLISTED_FILES.contains(path.basename(relative))) return false;
        return !path.split(relative).any(_BLACKLISTED_DIRS.contains);
      }).toList();
    });
  }
}
