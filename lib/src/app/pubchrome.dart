// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:html' as html;

import '../entrypoint.dart';
import '../io.dart' show FileSystem;
import '../log.dart' as log;
import '../source/hosted.dart';
import '../path_rep.dart';
import '../wrap/system_cache_wrap.dart';

void main() {
  new PubChrome();
}

class PubChrome {
  html.Element _logtext;
  html.InputElement _cwd;

  PubChrome() {
    // Store output fields for later access.
    _cwd = html.querySelector("#cwd");
    _logtext = html.querySelector("#logtext");

    // Attach listeners to the buttons.
    html.querySelector("#get_button").onClick.listen(runGet);
    html.querySelector("#change_dir").onClick.listen(changeWorkingDirectory);

    // Turn on the maximum level of logging, and send it to the page.
    log.showAll();
    log.addLoggerFunction(logToWindow);

    // Load the working directory from storage, or ask the user for one.
    var workingDir;
    FileSystem.restoreWorkingDirectory().then((dir) {
      if (dir != null)
        _cwd.value = dir.fullPath;
      else
        changeWorkingDirectory();
    });

    HostedSource.getHostedPackages().then((packages) => log.message(
        "Available packages: ${packages != null ? packages : 'None'}"));
  }

  /// Start the 'get' command for the currently selected working directory.
  void runGet(html.MouseEvent event) {
    SystemCache.withSources(FileSystem.workingDir.path.join("cache"))
        ..catchError((e) => log.error("Could not create system cache", e))
        .then((cache) => Entrypoint.load(FileSystem.workingDir.path, cache))
        .then((entrypoint) => entrypoint.acquireDependencies())
        .then((_) => log.fine("Got dependencies!"));
  }

  /// Log a single message [line] at importance level [level] to the page.
  void logToWindow(String line, String level) {
    var line_div = new html.DivElement();
    line_div.text = line;
    line_div.classes
        ..add("log")
        ..add("log_$level");
    _logtext.children.add(line_div);
  }

  /// Prompt the user to select a new working directory. The optional [event]
  /// is never used, just added to satisfy the button callback interface.
  void changeWorkingDirectory([html.MouseEvent event]) {
    FileSystem.obtainDirectory().then((dir) {
      if (dir != null) {
        _cwd.value = dir.fullPath;
        FileSystem.persistWorkingDirectory(dir);
      } else {
        _cwd.value = "Nothing currently selected.";
      }
    });
  }
}
