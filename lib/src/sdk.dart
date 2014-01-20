// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Operations relative to the user's installed Dart SDK.
library pub.sdk;

import 'package:path/path.dart' as path;

import 'io.dart';
import 'version.dart';
import 'wrap/sdk_wrap.dart';

/// Gets the path to the root directory of the SDK.
String get rootDirectory {
  // Assume the Dart executable is always coming from the SDK.
  return path.dirname(path.dirname(Platform.executable));
}

/// The SDK's revision number formatted to be a semantic version.
///
/// This can be set so that the version solver tests can artificially select
/// different SDK versions.
Version version = getVersion();