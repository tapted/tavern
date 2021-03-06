// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS d.file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_tests;

import 'package:scheduled_test/scheduled_test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';
import '../serve/utils.dart';

main() {
  initConfig();
  integration("fails to load a transform from a non-dependency", () {
    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "transformers": ["foo"]
      })
    ]).create();

    var pub = startPubServe();
    // Ignore the line containing the path to the pubspec.
    pub.stderr.expect(anything);
    pub.stderr.expect('"transformers.foo" refers to a package that\'s not a '
        'dependency.');
    pub.shouldExit(1);
  });
}
