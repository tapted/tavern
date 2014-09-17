// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub.source.path;

import 'dart:async';

import 'package:path/path.dart' as path;

import '../io.dart';
import '../package.dart';
import '../path_rep.dart';
import '../pubspec.dart';
import '../source.dart';
import '../utils.dart';

/// A package [Source] that gets packages from a given local file path.
class PathSource extends Source {
  final name = 'path';
  final shouldCache = false;

  Future<Pubspec> describeUncached(PackageId id) {
    return syncFuture(() {
      return  _validatePath(id.name, id.description).then((dir) {
        return Pubspec.load(dir, systemCache.sources,
          expectedName: id.name);
      });
    });
  }

  bool descriptionsEqual(description1, description2) {
    // Compare real paths after normalizing and resolving symlinks.
    // TODO(keertip): fix canonicalize to return a string,
    // right now it just returns the path
    var path1 = canonicalize(new PathRep(description1["path"]));
    var path2 = canonicalize(new PathRep(description2["path"]));
    // TODO(keertip): uncomment once canonicalize is fixed
    //return path1 == path2;
    return path1.fullPath == path2.fullPath;
  }

  Future<bool> get(PackageId id, PathRep destination) {
    return syncFuture(() {
      try {
        return _validatePath(id.name, id.description).then((dirName) {
          return createPackageSymlink(id.name, dirName, destination,
            relative: id.description["relative"]).then((dir) {
              if (dir != null)
                return true;
              else false;
          });
        });
      } on FormatException catch(err) {
        return false;
      }
    });
  }

  Future<PathRep> getDirectory(PackageId id) => _validatePath(id.name, id.description);

  /// Parses a path dependency. This takes in a path string and returns a map.
  /// The "path" key will be the original path but resolved relative to the
  /// containing path. The "relative" key will be `true` if the original path
  /// was relative.
  ///
  /// A path coming from a pubspec is a simple string. From a lock file, it's
  /// an expanded {"path": ..., "relative": ...} map.
  dynamic parseDescription(PathRep containingPath, description,
                           {bool fromLockFile: false}) {
    if (fromLockFile) {
      if (description is! Map) {
        throw new FormatException("The description must be a map.");
      }

      if (description["path"] is! String) {
        throw new FormatException("The 'path' field of the description must "
            "be a string.");
      }

      if (description["relative"] is! bool) {
        throw new FormatException("The 'relative' field of the description "
            "must be a boolean.");
      }

      return description;
    }

    if (description is! String) {
      throw new FormatException("The description must be a path string.");
    }

    // Resolve the path relative to the containing file path, and remember
    // whether the original path was relative or absolute.
    bool isRelative = path.isRelative(description);
    if (path.isRelative(description)) {
      // Can't handle relative paths coming from pubspecs that are not on the
      // local file system.
      assert(containingPath != null);
      description = path.normalize(
         path.join(path.dirname(containingPath.fullPath), description));

    }

    return {
      "path": description,
      "relative": isRelative
    };
  }

  /// Serializes path dependency's [description]. For the descriptions where
  /// `relative` attribute is `true`, tries to make `path` relative to the
  /// specified [containingPath].
  dynamic serializeDescription(PathRep containingPath, description) {
    if (description["relative"]) {
      return {
        "path": path.relative(description['path'], from: containingPath.fullPath),
        "relative": true
      };
    }
    return description;
  }

  /// Converts a parsed relative path to its original relative form.
  String formatDescription(PathRep containingPath, description) {
    var sourcePath = description["path"];
    if (description["relative"]) {
      sourcePath = path.relative(description['path'], from: containingPath.fullPath);
    }

    return sourcePath;
  }

  /// Ensures that [description] is a valid path description and returns a
  /// normalized path to the package.
  ///
  /// It must be a map, with a "path" key containing a path that points to an
  /// existing directory. Throws an [ApplicationException] if the path is
  /// invalid.
  Future<PathRep> _validatePath(String name, description) {
    var dir = description["path"];

    return dirExists(new PathRep(dir)).then((result) {
      if (result)
        return new PathRep(dir);
          throw new PackageNotFoundException(
                 'Could not find package $name at "$dir".');
      });
  }
}
