// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Helper functionality to make working with IO easier.
library pub.io;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:path/path.dart' as path;
import 'package:stack_trace/stack_trace.dart';

import 'exit_codes.dart' as exit_codes;
import 'error_group.dart';
import 'log.dart' as log;
import 'path_rep.dart';
import 'pool.dart';
import 'sdk.dart' as sdk;
import 'utils.dart';
import 'wrap/http_wrap.dart' show ByteStream;
import 'wrap/io_wrap.dart';

export 'wrap/http_wrap.dart' show ByteStream;
export 'wrap/io_wrap.dart';

/// The pool used for restricting access to asynchronous operations that consume
/// file descriptors.
///
/// The maximum number of allocated descriptors is based on empirical tests that
/// indicate that beyond 32, additional file reads don't provide substantial
/// additional throughput.
final _descriptorPool = new Pool(32);

/// Returns whether or not [entry] is nested somewhere within [dir]. This just
/// performs a path comparison; it doesn't look at the actual filesystem.
bool isBeneath(String entry, String dir) {
  var relative = path.relative(entry, from: dir);
  return !path.isAbsolute(relative) && path.split(relative)[0] != '..';
}

/// Determines if a file or directory exists at [path].
Future<bool> entryExists(PathRep path) {
  return Future.wait([dirExists(path),
                      fileExists(path),
                      linkExists(path)]).then((results) {
    return results.any((elem) => elem);
  });
}

/// Returns whether [link] exists on the file system. This will return `true`
/// for any symlink, regardless of what it points at or whether it's broken.
Future<bool> linkExists(PathRep link) =>
    Link.load(link).then((res) => res != null);

/// Returns whether [file] exists on the file system. This will return `true`
/// for a symlink only if that symlink is unbroken and points to a file.
Future<bool> fileExists(PathRep file) =>
    File.load(file).then((res) => res != null);

/// Returns the canonical path for [pathString]. This is the normalized,
/// absolute path, with symlinks resolved. As in [transitiveTarget], broken or
/// recursive symlinks will not be fully resolved.
///
/// This doesn't require [pathString] to point to a path that exists on the
/// filesystem; nonexistent or unreadable path entries are treated as normal
/// directories.
PathRep canonicalize(PathRep path) {
  return canonicalizeNative(path);
}

/// Returns the transitive target of [link] (if A links to B which links to C,
/// this will return C). If [link] is part of a symlink loop (e.g. A links to B
/// which links back to A), this returns the path to the first repeated link (so
/// `transitiveTarget("A")` would return `"A"` and `transitiveTarget("A")` would
/// return `"B"`).
///
/// This accepts paths to non-links or broken links, and returns them as-is.
PathRep resolveLink(PathRep link) {
  return link.target;
}

/// Creates a new symlink at path [symlink] that points to [target]. Returns a
/// [Future] which completes to the path to the symlink file.
///
/// If [relative] is true, creates a symlink with a relative path from the
/// symlink to the target. Otherwise, uses the [target] path unmodified.
///
/// Note that on Windows, only directories may be symlinked to.
Future createSymlink(PathRep target, PathRep symlink,
                     {bool relative: false}) {
  return deleteEntry(symlink).then((_) =>
      createSymlinkNative(target, symlink, relative: relative));
}

/// Reads the contents of the text file [file].
Future<String> readTextFile(PathRep file) =>
    File.load(file).then((file) => file != null ? file.readText() : null);

/// Reads the contents of the binary file [file].
Future<List<int>> readBinaryFile(PathRep file) {
  log.io("Reading binary file $file.");
  return File.load(file)
      .then((file) => file != null ? file.readBytes() : null)
      .then((contents) {
        if (contents != null)
          log.io("Read ${contents.length} bytes from $file.");
        return contents;
      });
}

/// Creates [file] and writes [contents] to it.
///
/// If [dontLogContents] is true, the contents of the file will never be logged.
Future writeTextFile(PathRep file, String contents,
  {bool dontLogContents: false}) {
  // Sanity check: don't spew a huge file.
  log.io("Writing ${contents.length} characters to text file $file.");
  if (!dontLogContents && contents.length < 1024 * 1024) {
    log.fine("Contents:\n$contents");
  }

  return File.create(file).then((file) => file.writeText(contents));
}

/// Creates [file] and writes [contents] to it.
Future<File> writeBinaryFile(PathRep file, List<int> contents) {
  log.io("Writing ${contents.length} bytes to binary file $file.");
  return File.create(file).then((file) => file..write(contents));
}

/// Writes [stream] to a new file at path [file]. Will replace any file already
/// at that path. Completes when the file is done being written.
Future<String> createFileFromStream(Stream<List<int>> stream, PathRep file) {
  // TODO(nweiz): remove extra logging when we figure out the windows bot issue.
  log.io("Creating $file from stream.");

  return _descriptorPool.withResource(() {
    return Chain.track(File.create(file).then((_) {
      log.fine("Created $file from stream.");
      return file;
    }));
  });
}

/// Copy all files in [files] to the directory [destination]. Their locations in
/// [destination] will be determined by their relative location to [baseDir].
/// Any existing files at those paths will be overwritten.
void copyFiles(Iterable<String> files, String baseDir, String destination) {
  for (var file in files) {
    var newPath = path.join(destination, path.relative(file, from: baseDir));
    ensureDir(path.dirname(newPath));
    copyFile(file, newPath);
  }
}

/// Copy a file from [source] to [destination].
Future copyFile(PathRep source, PathRep destination) {
  return File.load(source).then((file) => file.copyTo(destination));
}

/// Creates a directory [dir].
Future<String> createDir(PathRep dir) =>
    Directory.create(dir).then((_) => dir);

/// Ensures that [dir] and all its parent directories exist. If they don't
/// exist, creates them.
Future<String> ensureDir(PathRep dir) => createDir(dir);

/// Creates a temp directory in [dir], whose name will be [prefix] with
/// characters appended to it to make a unique name.
/// Returns the path of the created directory.
Future<String> createTempDir(PathRep dir, String prefix) {
  return Directory.load(dir).then((parent) {
    // TODO(pajamallama): Request a temp directory using HTML5 filesystem API.
    var name = prefix + (new Random()).nextInt(10000).toString();
    return parent.createDirectory(name);
  }).then((dir) {
    log.io("Created temp directory ${dir.name}");
    return dir.name;
  });
}

/// Creates a temp directory in the system temp directory, whose name will be
/// 'pub_' with characters appended to it to make a unique name.
/// Returns the path of the created directory.
// TODO(pajamallama): Actually place this in the system directory.
Future<String> createSystemTempDir() =>
    createTempDir(FileSystemEntity.workingDir.path, "pub_");

/// Lists the contents of [dir]. If [recursive] is `true`, lists subdirectory
/// contents (defaults to `false`). If [includeHidden] is `true`, includes files
/// and directories beginning with `.` (defaults to `false`).
///
/// The returned paths are guaranteed to begin with [dir].
Future<List<PathRep>> listDir(PathRep dir,
                              {bool recursive: false,
                               bool includeHidden: true,
                               bool includePackages: true}) {

  return Directory.load(dir)
      .then((dir) => dir == null ? [] : dir.list(
          recursive: recursive,
          includeHidden: includeHidden,
          includePackages: includePackages))
      .then((entries) => entries.map((entry) => entry.path));
}

/// Returns whether [dir] exists on the file system. This will return `true` for
/// a symlink only if that symlink is unbroken and points to a directory.
Future<bool> dirExists(PathRep dir) =>
    Directory.load(dir).then((res) => res != null);

/// Deletes whatever's at [path], whether it's a file, directory, or symlink. If
/// it's a directory, it will be deleted recursively. Ignore any errors so that
/// deleteEntry for a non-existant [path] will be a success.
Future deleteEntry(PathRep path) {
  log.io("Deleting $path.");

  return FileSystemEntity.load(path).then((entry) {
    if (entry != null) return entry.remove();
  });
}

/// "Cleans" [dir]. If that directory already exists, it will be deleted. Then a
/// new empty directory will be created.
Future cleanDir(PathRep dir) {
  return Directory.load(dir)
      .then((dir) {
        if (dir != null) return dir.remove();
      }).then((_) => Directory.create(dir));
}

/// Renames (i.e. moves) the directory [from] to [to].
void renameDir(PathRep from, PathRep to) {
  log.io("Renaming directory $from to $to.");
  Directory.load(from)
      .then((dir) => dir.rename(to))
      .catchError((error) => fail("Failed to move dir: $error"));
}

/// Creates a new symlink that creates an alias at [symlink] that points to the
/// `lib` directory of package [target]. If [target] does not have a `lib`
/// directory, this shows a warning if appropriate and then does nothing.
///
/// If [relative] is true, creates a symlink with a relative path from the
/// symlink to the target. Otherwise, uses the [target] path unmodified.
Future createPackageSymlink(String name, PathRep target, PathRep symlink,
    {bool isSelfLink: false, bool relative: false}) {
  // See if the package has a "lib" directory. If not, there's nothing to
  // symlink to.
  target = target.join('lib');
  log.fine("Creating ${isSelfLink ? "self" : ""}link for package '$name'.");
  return dirExists(target).then((exists) {
    if (exists) {
      return createSymlink(target, symlink, relative: relative);
    }
  });
}

/// Resolves [target] relative to the path to pub's `resource` directory.
String resourcePath(String target) {
  if (runningFromSdk) {
    return path.join(
        sdk.rootDirectory, 'lib', '_internal', 'pub', 'resource', target);
  } else {
    return path.join(
        path.dirname(libraryPath('pub.io')), '..', '..', 'resource', target);
  }
}

/// Returns the path to the root of the Dart repository. This will throw a
/// [StateError] if it's called when running pub from the SDK.
String get repoRoot {
  if (runningFromSdk) {
    throw new StateError("Can't get the repo root from the SDK.");
  }
  return path.join(
      path.dirname(libraryPath('pub.io')), '..', '..', '..', '..', '..', '..');
}

/// A line-by-line stream of standard input.
final Stream<String> stdinLines = streamToLines(
    new ByteStream(Chain.track(stdin)).toStringStream());

/// Displays a message and reads a yes/no confirmation from the user. Returns
/// a [Future] that completes to `true` if the user confirms or `false` if they
/// do not.
///
/// This will automatically append " (y/n)?" to the message, so [message]
/// should just be a fragment like, "Are you sure you want to proceed".
Future<bool> confirm(String message) {
  log.fine('Showing confirm message: $message');
  if (runningAsTest) {
    log.message("$message (y/n)?");
  } else {
    stdout.write("$message (y/n)? ");
  }
  return streamFirst(stdinLines)
      .then((line) => new RegExp(r"^[yY]").hasMatch(line));
}

/// Reads and discards all output from [stream]. Returns a [Future] that
/// completes when the stream is closed.
Future drainStream(Stream stream) {
  return stream.fold(null, (x, y) {});
}

/// Flushes the stdout and stderr streams, then exits the program with the given
/// status code.
///
/// This returns a Future that will never complete, since the program will have
/// exited already. This is useful to prevent Future chains from proceeding
/// after you've decided to exit.
Future flushThenExit(int status) {
  return Future.wait([
    Chain.track(stdout.close()),
    Chain.track(stderr.close())
  ]).then((_) => exit(status));
}

/// Returns a [EventSink] that pipes all data to [consumer] and a [Future] that
/// will succeed when [EventSink] is closed or fail with any errors that occur
/// while writing.
Pair<EventSink, Future> consumerToSink(StreamConsumer consumer) {
  var controller = new StreamController(sync: true);
  var done = controller.stream.pipe(consumer);
  return new Pair<EventSink, Future>(controller.sink, done);
}

// TODO(nweiz): remove this when issue 7786 is fixed.
/// Pipes all data and errors from [stream] into [sink]. When [stream] is done,
/// the returned [Future] is completed and [sink] is closed if [closeSink] is
/// true.
///
/// When an error occurs on [stream], that error is passed to [sink]. If
/// [cancelOnError] is true, [Future] will be completed successfully and no
/// more data or errors will be piped from [stream] to [sink]. If
/// [cancelOnError] and [closeSink] are both true, [sink] will then be
/// closed.
Future store(Stream stream, EventSink sink,
    {bool cancelOnError: true, bool closeSink: true}) {
  var completer = new Completer();
  stream.listen(sink.add, onError: (e, stackTrace) {
    sink.addError(e, stackTrace);
    if (cancelOnError) {
      completer.complete();
      if (closeSink) sink.close();
    }
  }, onDone: () {
    if (closeSink) sink.close();
    completer.complete();
  }, cancelOnError: cancelOnError);
  return completer.future;
}

/// Spawns and runs the process located at [executable], passing in [args].
/// Returns a [Future] that will complete with the results of the process after
/// it has ended.
///
/// The spawned process will inherit its parent's environment variables. If
/// [environment] is provided, that will be used to augment (not replace) the
/// the inherited variables.
Future<PubProcessResult> runProcess(String executable, List<String> args,
    {workingDir, Map<String, String> environment}) {
  return _descriptorPool.withResource(() {
    return _doProcess(Process.run, executable, args, workingDir, environment)
        .then((result) {
      // TODO(rnystrom): Remove this and change to returning one string.
      List<String> toLines(String output) {
        var lines = splitLines(output);
        if (!lines.isEmpty && lines.last == "") lines.removeLast();
        return lines;
      }

      var pubResult = new PubProcessResult(toLines(result.stdout),
                                  toLines(result.stderr),
                                  result.exitCode);

      log.processResult(executable, pubResult);
      return pubResult;
    });
  });
}

/// Spawns the process located at [executable], passing in [args]. Returns a
/// [Future] that will complete with the [Process] once it's been started.
///
/// The spawned process will inherit its parent's environment variables. If
/// [environment] is provided, that will be used to augment (not replace) the
/// the inherited variables.
Future<PubProcess> startProcess(String executable, List<String> args,
    {workingDir, Map<String, String> environment}) {
  return _descriptorPool.request().then((resource) {
    return _doProcess(Process.start, executable, args, workingDir, environment)
        .then((ioProcess) {
      var process = new PubProcess(ioProcess);
      process.exitCode.whenComplete(resource.release);
      return process;
    });
  });
}

/// A wrapper around [Process] that exposes `dart:async`-style APIs.
class PubProcess {
  /// The underlying `dart:io` [Process].
  final Process _process;

  /// The mutable field for [stdin].
  EventSink<List<int>> _stdin;

  /// The mutable field for [stdinClosed].
  Future _stdinClosed;

  /// The mutable field for [stdout].
  ByteStream _stdout;

  /// The mutable field for [stderr].
  ByteStream _stderr;

  /// The mutable field for [exitCode].
  Future<int> _exitCode;

  /// The sink used for passing data to the process's standard input stream.
  /// Errors on this stream are surfaced through [stdinClosed], [stdout],
  /// [stderr], and [exitCode], which are all members of an [ErrorGroup].
  EventSink<List<int>> get stdin => _stdin;

  // TODO(nweiz): write some more sophisticated Future machinery so that this
  // doesn't surface errors from the other streams/futures, but still passes its
  // unhandled errors to them. Right now it's impossible to recover from a stdin
  // error and continue interacting with the process.
  /// A [Future] that completes when [stdin] is closed, either by the user or by
  /// the process itself.
  ///
  /// This is in an [ErrorGroup] with [stdout], [stderr], and [exitCode], so any
  /// error in process will be passed to it, but won't reach the top-level error
  /// handler unless nothing has handled it.
  Future get stdinClosed => _stdinClosed;

  /// The process's standard output stream.
  ///
  /// This is in an [ErrorGroup] with [stdinClosed], [stderr], and [exitCode],
  /// so any error in process will be passed to it, but won't reach the
  /// top-level error handler unless nothing has handled it.
  ByteStream get stdout => _stdout;

  /// The process's standard error stream.
  ///
  /// This is in an [ErrorGroup] with [stdinClosed], [stdout], and [exitCode],
  /// so any error in process will be passed to it, but won't reach the
  /// top-level error handler unless nothing has handled it.
  ByteStream get stderr => _stderr;

  /// A [Future] that will complete to the process's exit code once the process
  /// has finished running.
  ///
  /// This is in an [ErrorGroup] with [stdinClosed], [stdout], and [stderr], so
  /// any error in process will be passed to it, but won't reach the top-level
  /// error handler unless nothing has handled it.
  Future<int> get exitCode => _exitCode;

  /// Creates a new [PubProcess] wrapping [process].
  PubProcess(Process process)
    : _process = process {
    var errorGroup = new ErrorGroup();

    var pair = consumerToSink(process.stdin);
    _stdin = pair.first;
    _stdinClosed = errorGroup.registerFuture(Chain.track(pair.last));

    _stdout = new ByteStream(
        errorGroup.registerStream(Chain.track(process.stdout)));
    _stderr = new ByteStream(
        errorGroup.registerStream(Chain.track(process.stderr)));

    var exitCodeCompleter = new Completer();
    _exitCode = errorGroup.registerFuture(
        Chain.track(exitCodeCompleter.future));
    _process.exitCode.then((code) => exitCodeCompleter.complete(code));
  }

  /// Sends [signal] to the underlying process.
  bool kill([ProcessSignal signal = ProcessSignal.SIGTERM]) =>
    _process.kill(signal);
}

/// Calls [fn] with appropriately modified arguments. [fn] should have the same
/// signature as [Process.start], except that the returned [Future] may have a
/// type other than [Process].
Future _doProcess(Function fn, String executable, List<String> args,
    String workingDir, Map<String, String> environment) {
  // TODO(rnystrom): Should dart:io just handle this?
  // Spawning a process on Windows will not look for the executable in the
  // system path. So, if executable looks like it needs that (i.e. it doesn't
  // have any path separators in it), then spawn it through a shell.
  if ((Platform.operatingSystem == "windows") &&
      (executable.indexOf('\\') == -1)) {
    args = flatten(["/c", executable, args]);
    executable = "cmd";
  }

  log.process(executable, args, workingDir == null ? '.' : workingDir);

  return Chain.track(fn(executable,
      args,
      workingDirectory: workingDir,
      environment: environment));
}

/// Wraps [input] to provide a timeout. If [input] completes before
/// [milliseconds] have passed, then the return value completes in the same way.
/// However, if [milliseconds] pass before [input] has completed, it completes
/// with a [TimeoutException] with [description] (which should be a fragment
/// describing the action that timed out).
///
/// Note that timing out will not cancel the asynchronous operation behind
/// [input].
Future timeout(Future input, int milliseconds, String description) {
  // TODO(nwiez): Replace this with [Future.timeout].
  var completer = new Completer();
  var duration = new Duration(milliseconds: milliseconds);
  var timer = new Timer(duration, () {
    completer.completeError(new TimeoutException(
        'Timed out while $description.', duration),
        new Chain.current());
  });
  input.then((value) {
    if (completer.isCompleted) return;
    timer.cancel();
    completer.complete(value);
  }).catchError((e, stackTrace) {
    if (completer.isCompleted) return;
    timer.cancel();
    completer.completeError(e, stackTrace);
  });
  return completer.future;
}

/// Creates a temporary directory and passes its path to [fn]. Once the [Future]
/// returned by [fn] completes, the temporary directory and all its contents
/// will be deleted. [fn] can also return `null`, in which case the temporary
/// directory is deleted immediately afterwards.
///
/// Returns a future that completes to the value that the future returned from
/// [fn] completes to.
Future withTempDir(Future fn(String path)) {
  return syncFuture(() {
    var tempDir = createSystemTempDir();
    return syncFuture(() => fn(tempDir))
        .whenComplete(() => deleteEntry(tempDir));
  });
}

// TODO(pajamallam): Extract the rest of this file into io_wrap.dart
// for the Dartium wrapper.
/// Extracts a `.tar.gz` file from [stream] to [destination]. Returns whether
/// or not the extraction was successful.
Future<bool> extractTarGz(Stream<List<int>> stream, String destination) {
  log.fine("Extracting .tar.gz stream to $destination.");

  if (Platform.operatingSystem == "windows") {
    return _extractTarGzWindows(stream, destination);
  }

  return startProcess("tar",
      ["--extract", "--gunzip", "--directory", destination]).then((process) {
    // Ignore errors on process.std{out,err}. They'll be passed to
    // process.exitCode, and we don't want them being top-levelled by
    // std{out,err}Sink.
    store(process.stdout.handleError((_) {}), stdout, closeSink: false);
    store(process.stderr.handleError((_) {}), stderr, closeSink: false);
    return Future.wait([
      store(stream, process.stdin),
      process.exitCode
    ]);
  }).then((results) {
    var exitCode = results[1];
    if (exitCode != exit_codes.SUCCESS) {
      throw new Exception("Failed to extract .tar.gz stream to $destination "
          "(exit code $exitCode).");
    }
    log.fine("Extracted .tar.gz stream to $destination. Exit code $exitCode.");
  });
}

String get pathTo7zip {
  if (runningFromSdk) return resourcePath(path.join('7zip', '7za.exe'));
  return path.join(repoRoot, 'third_party', '7zip', '7za.exe');
}

Future<bool> _extractTarGzWindows(Stream<List<int>> stream,
    String destination) {
  // TODO(rnystrom): In the repo's history, there is an older implementation of
  // this that does everything in memory by piping streams directly together
  // instead of writing out temp files. The code is simpler, but unfortunately,
  // 7zip seems to periodically fail when we invoke it from Dart and tell it to
  // read from stdin instead of a file. Consider resurrecting that version if
  // we can figure out why it fails.

  return withTempDir((tempDir) {
    // Write the archive to a temp file.
    var dataFile = path.join(tempDir, 'data.tar.gz');
    return createFileFromStream(stream, dataFile).then((_) {
      // 7zip can't unarchive from gzip -> tar -> destination all in one step
      // first we un-gzip it to a tar file.
      // Note: Setting the working directory instead of passing in a full file
      // path because 7zip says "A full path is not allowed here."
      return runProcess(pathTo7zip, ['e', 'data.tar.gz'], workingDir: tempDir);
    }).then((result) {
      if (result.exitCode != exit_codes.SUCCESS) {
        throw new Exception('Could not un-gzip (exit code ${result.exitCode}). '
                'Error:\n'
            '${result.stdout.join("\n")}\n'
            '${result.stderr.join("\n")}');
      }

      // Find the tar file we just created since we don't know its name.
      var tarFile = listDir(tempDir).firstWhere(
          (file) => path.extension(file) == '.tar',
          orElse: () {
        throw new FormatException('The gzip file did not contain a tar file.');
      });

      // Untar the archive into the destination directory.
      return runProcess(pathTo7zip, ['x', tarFile], workingDir: destination);
    }).then((result) {
      if (result.exitCode != exit_codes.SUCCESS) {
        throw new Exception('Could not un-tar (exit code ${result.exitCode}). '
                'Error:\n'
            '${result.stdout.join("\n")}\n'
            '${result.stderr.join("\n")}');
      }
      return true;
    });
  });
}

/// Create a .tar.gz archive from a list of entries. Each entry can be a
/// [String], [Directory], or [File] object. The root of the archive is
/// considered to be [baseDir], which defaults to the current working directory.
/// Returns a [ByteStream] that will emit the contents of the archive.
ByteStream createTarGz(List contents, {baseDir}) {
  return new ByteStream(futureStream(syncFuture(() {
    var buffer = new StringBuffer();
    buffer.write('Creating .tag.gz stream containing:\n');
    contents.forEach((file) => buffer.write('$file\n'));
    log.fine(buffer.toString());

    if (baseDir == null) baseDir = path.current;
    baseDir = path.absolute(baseDir);
    contents = contents.map((entry) {
      entry = path.absolute(entry);
      if (!isBeneath(entry, baseDir)) {
        throw new ArgumentError('Entry $entry is not inside $baseDir.');
      }
      return path.relative(entry, from: baseDir);
    }).toList();

    if (Platform.operatingSystem != "windows") {
      var args = ["--create", "--gzip", "--directory", baseDir];
      args.addAll(contents);
      // TODO(nweiz): It's possible that enough command-line arguments will
      // make the process choke, so at some point we should save the arguments
      // to a file and pass them in via --files-from for tar and -i@filename
      // for 7zip.
      return startProcess("tar", args).then((process) => process.stdout);
    }

    // Don't use [withTempDir] here because we don't want to delete the temp
    // directory until the returned stream has closed.
    var tempDir = createSystemTempDir();
    return syncFuture(() {
      // Create the tar file.
      var tarFile = path.join(tempDir, "intermediate.tar");
      var args = ["a", "-w$baseDir", tarFile];
      args.addAll(contents.map((entry) => '-i!$entry'));

      // We're passing 'baseDir' both as '-w' and setting it as the working
      // directory explicitly here intentionally. The former ensures that the
      // files added to the archive have the correct relative path in the
      // archive. The latter enables relative paths in the "-i" args to be
      // resolved.
      return runProcess(pathTo7zip, args, workingDir: baseDir).then((_) {
        // GZIP it. 7zip doesn't support doing both as a single operation.
        // Send the output to stdout.
        args = ["a", "unused", "-tgzip", "-so", tarFile];
        return startProcess(pathTo7zip, args);
      }).then((process) => process.stdout);
    }).then((stream) {
      return stream.transform(onDoneTransformer(() => deleteEntry(tempDir)));
    }).catchError((e) {
      deleteEntry(tempDir);
      throw e;
    });
  })));
}

/// Contains the results of invoking a [Process] and waiting for it to complete.
class PubProcessResult {
  final List<String> stdout;
  final List<String> stderr;
  final int exitCode;

  const PubProcessResult(this.stdout, this.stderr, this.exitCode);

  bool get success => exitCode == exit_codes.SUCCESS;
}

/// Gets a [Uri] for [uri], which can either already be one, or be a [String].
Uri _getUri(uri) {
  if (uri is Uri) return uri;
  return Uri.parse(uri);
}
