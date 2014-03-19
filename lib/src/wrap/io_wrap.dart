library pub.io_wrap;

import 'dart:async';
import 'dart:convert';
import 'dart:html' show Blob;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chrome/chrome_app.dart' as chrome;
import 'package:range/range.dart';

import '../log.dart' as log;
import '../path_rep.dart';

// Extension of the Archive files being used (tarball).
const String ARCHIVE = "tar.gz";

class OSError { }

/// A collection of static methods for accessing important parts of the local
/// filesystem.
class FileSystem {
  static Directory workingDir;
  static PathRep workingDirPath() => workingDir.path;
  static const String STORAGE_KEY = "WORKING_DIR";

  /// Ask the user to select a directory from a file selection widget.
  static Future<Directory> obtainDirectory() {
    chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
        type: chrome.ChooseEntryType.OPEN_DIRECTORY
    );

    return chrome.fileSystem.chooseEntry(options)
        .then((chrome.ChooseEntryResult result) => new Directory(result.entry));
  }

  /// Load the working directory for the current project (the directory
  /// that contains the pubspec.yaml file) from local storage. Any errors
  /// complete with null (e.g. if a working directory hasn't been set before).
  static Future<Directory> restoreWorkingDirectory() {
    if (!chrome.storage.available) return new Future.value();

    return chrome.storage.local.get(STORAGE_KEY).then((map) {
      if (map[STORAGE_KEY] is! String) return null;

      return chrome.fileSystem.restoreEntry(map[STORAGE_KEY])
          .then((entry) => new Directory(entry))
          ..then((dir) => workingDir = dir)
          .catchError((_) => null);
    });
  }

  /// Sets the working directory to [dir] in the local storage.
  static void persistWorkingDirectory(Directory dir) {
    workingDir = dir;
    if (chrome.storage.available) {
      String entryID = chrome.fileSystem.retainEntry(dir.getEntry());
      chrome.storage.local.set({STORAGE_KEY: entryID});
    }
  }
}

/// A generic entity that lives within the filesystem. The subclasses File,
/// Directory, Link should be used directly.
abstract class FileSystemEntity {
  PathRep getPath();
  chrome.Entry getEntry();

  PathRep get path => getPath();
  String get name => getPath().name;
  String get fullPath => getPath().fullPath;

  bool get isFile => getEntry().isFile;
  bool get isDirectory => getEntry().isDirectory;

  /// Load a filesystem entity at the location [path]. Returns null if nothing
  /// exists there.
  static Future<FileSystemEntity> load(PathRep path) {
    return File.load(path).then((file) =>
        file != null ? new Future.value(file) : Directory.load(path));
  }

  Future copyTo(PathRep dir, {String name}) {
    return Directory.create(dir).then(
        (newParent) => getEntry().copyTo(newParent.getEntry(), name: name));
  }

  Future moveTo(PathRep dir, {String name}) {
    return Directory.create(dir).then(
        (newParent) => getEntry().moveTo(newParent.getEntry(), name: name));
  }

  Future remove();
}

/// An object which refers to a normal file (i.e. not a directory or symlink)
/// in the local filesystem. Basically a wrapper of chrome.ChromeFileEntry.
class File extends FileSystemEntity {
  PathRep _path;
  chrome.ChromeFileEntry _entry;

  PathRep getPath() => _path;
  chrome.Entry getEntry() => _entry;

  /// Private File constructor that shouldn't be used. File.load & File.create
  /// are the public interfaces to creating a File.
  File(entry) : _entry = entry, _path = new PathRep(entry.fullPath);

  /// Load a file at the location [file]. Returns null if it doesn't exist.
  static Future<File> load(PathRep file) {
    return FileSystem.workingDir.getFile(file).catchError((_) => null);
  }

  /// Create a file at the location [file] and all necessary parent folders.
  static Future<File> create(PathRep file) {
    return Directory.create(file.dirname).then(
        (parent) => parent.createFile(file.basename));
  }

  Future remove() {
    return _entry.remove();
  }

  Future<List<int>> readBytes() {
    return _entry.readBytes().then((arraybuff) => arraybuff.getBytes());
  }

  Future<String> readText() => _entry.readText();

  Future write(Uint8List data) =>
      _entry.writeBytes(new chrome.ArrayBuffer.fromBytes(data));

  Future writeText(String s) => _entry.writeText(s);
}

/// An object which refers to a directory in the local filesystem. Basically a
/// wrapper of chrome.DirectoryEntry.
class Directory extends FileSystemEntity {
  PathRep _path;
  chrome.DirectoryEntry _entry;

  PathRep getPath() => _path;
  chrome.Entry getEntry() => _entry;

  /// Private Directory constructor that shouldn't be used. Directory.load &
  /// Directory.create are the public interfaces to creating a Directory.
  Directory(entry) : _entry = entry, _path = new PathRep(entry.fullPath);

  /// Delete this directory and all contents recursively.
  Future remove() => _entry.removeRecursively();

  /// Load a directory at the location [dir]. Returns null if it doesn't exist.
  static Future<Directory> load(PathRep dir) {
    return FileSystem.workingDir.getDirectory(dir).catchError((_) => null);
  }

  /// Create a directory at the location [dir] and all necessary
  /// parent folders (i.e. same is mkdir -p).
  static Future<Directory> create(PathRep dir) => _create(dir);

  /// Implementation of create([dir]) where [dir] is split into parts,
  /// [folders] stores the remaining directories to check/create, and
  /// [parent] stores the current directory being used.
  static Future<Directory> _create(PathRep dir,
                                  [Directory parent,
                                  List<String> folders]) {
    if (parent == null) parent = FileSystem.workingDir;
    if (folders == null) folders = dir.relativeTo(parent.path).split();
    if (folders.length == 0) return Directory.load(dir);

    return parent.createDirectory(folders[0]).then((dirEntry) {
      folders.removeAt(0);
      return Directory._create(dir, dirEntry, folders);
    });
  }

  /// Create a file named [file] immediately inside this directory.
  Future<File> createFile(String file) =>
      _entry.createFile(file).then((entry) => new File(entry));

  /// Create a directory named [dir] immediately inside this directory.
  Future<Directory> createDirectory(String dir) =>
      _entry.createDirectory(dir).then((entry) => new Directory(entry));

  /// Load the location [path] and return either a File object.
  Future<FileSystemEntity> getFile(PathRep path) {
    String relative = path.relativeTo(_path).fullPath;
    return _entry.getFile(relative).then((entry) => new File(entry));
  }

  /// Load the location [path] and return either a Directory object.
  Future<FileSystemEntity> getDirectory(PathRep path) {
    String relative = path.relativeTo(_path).fullPath;
    return _entry.getDirectory(relative).then((entry) => new Directory(entry));
  }

  /// List all the files in this directory.
  // TODO(pajamallama): Test whether .readEntries is recursive or not.
  // And add the includeHidden/includePackages functionality.
  Future<List<FileSystemEntity>> list({bool recursive: false,
                                       bool includeHidden: true,
                                       bool includePackages: true}) {
    return _entry.createReader().readEntries().then((entries) => entries.map(
        (entry) => entry.isFile ? new File(entry) : new Directory(entry)));
  }

  /// Extract the archive inside the current directory.
  Future extractArchive(ByteBuffer data, {bool skipTopDir: false}) {
    log.message("Extracting zipped data to $path.");

    Uint8List gzData = new Uint8List.view(data);
    List<int> tarData = (new GZipDecoder()).decodeBytes(gzData);
    Archive archive = (new TarDecoder()).decodeBytes(tarData);

    return Future.forEach(archive.files, (ArchiveFile zipFile) {
      var zipFilename = zipFile.name;
      // If the zip file has all its contents inside a top directory then
      // sometimes we want to extract them up a level.
      if (skipTopDir) {
        var parts = zipFilename.split('/');

        // Skip files in the top directory
        if (parts.length == 1) return null;

        parts.removeAt(0);
        zipFilename = parts.join('/');
      }
      var path = getPath().join(zipFilename);

      if (zipFile.isFile) {
        return File.create(path).then((file) => file.write(zipFile.content));
      } else {
        return Directory.create(path);
      }
    });
  }
}

/// An object which refers to a symbolic link in the local filesystem.
// TODO(pajamallama): Sort out symlinks.
class Link extends File {
  /// Private Link constructor that shouldn't be used. Link.load & Link.create
  /// are the public interfaces to creating a Link.
  Link(entry) : super(entry);

  /// Load a link at the location [link]. Returns null if it doesn't exist.
  static Future<Link> load(PathRep link) => File.load(link);

  /// Create a link at the location [link] and all necessary parent folders.
  static Future<Link> create(PathRep link) {
    return File.create(link);
  }

  Future<PathRep> target() {
    return new Future.sync(() => new PathRep(""));
  }

  Future setTarget(target) {
    return new Future.sync(() => new PathRep(""));
  }
}

class Platform {
  static String get executable => "";
  static String get operatingSystem => "";
  static Map<String, String> get environment =>
      {"_PUB_TEST_SDK_VERSION": "1.0.0"};
}

class IOSink {
  void write(Object obj) {
    print(obj);
  }
  void writeln([Object obj = ""]) {
    write(obj);
    write("\n");
  }
}

IOSink _stdin;
IOSink _stdout;
IOSink _stderr;

IOSink get stdin {
  if (_stdin == null) {
    _stdin = new IOSink();
  }
  return _stdin;
}

IOSink get stdout {
  if (_stdout == null) {
    _stdout = new IOSink();
  }
  return _stdout;
}

IOSink get stderr {
  if (_stderr == null) {
    _stderr = new IOSink();
  }
  return _stderr;
}

class StdioType {
  static const StdioType TERMINAL = const StdioType._("terminal");
  static const StdioType PIPE = const StdioType._("pipe");
  static const StdioType FILE = const StdioType._("file");
  static const StdioType OTHER = const StdioType._("other");
  final String name;
  const StdioType._(String this.name);
  String toString() => "StdioType: $name";
}

StdioType stdioType(object) {
  return StdioType.PIPE;
}

abstract class InternetAddress { }

class SocketException implements Exception {
  final String message;
  final OSError osError;
  final InternetAddress address;
  final int port;

  const SocketException(this.message, {this.osError, this.address, this.port});

  String toString() {
    StringBuffer sb = new StringBuffer();
    sb.write("SocketException");
    if (!message.isEmpty) {
      sb.write(": $message");
      if (osError != null) {
        sb.write(" ($osError)");
      }
    } else if (osError != null) {
      sb.write(": $osError");
    }
    if (address != null) {
      sb.write(", address = ${address.host}");
    }
    if (port != null) {
      sb.write(", port = $port");
    }
    return sb.toString();
  }
}

/// Whether pub is running from within the Dart SDK, as opposed to from the Dart
/// source repository.
bool get runningFromSdk => false;

/// Creates a new symlink at path [symlink] that points to [target]. Returns a
/// [Future] which completes to the path to the symlink file.
///
/// If [relative] is true, creates a symlink with a relative path from the
/// symlink to the target. Otherwise, uses the [target] path unmodified.
///
/// Note that on Windows, only directories may be symlinked to.
Future createSymlinkNative(PathRep target, PathRep symlink,
                           {bool relative: false}) {
  log.fine("Creating $symlink pointing to $target");
  return Directory.load(target).then((from) {
    if (from == null) {
      log.error("Can't create symlink to target folder: $target");
      return null;
    }
    return from.copyTo(symlink.dirname, name: symlink.basename);
  });
}

/// Returns the canonical path for [pathString]. This is the normalized,
/// absolute path, with symlinks resolved. As in [transitiveTarget], broken or
/// recursive symlinks will not be fully resolved.
///
/// This doesn't require [pathString] to point to a path that exists on the
/// filesystem; nonexistent or unreadable path entries are treated as normal
/// directories.
// TODO(pajamallama): Throw UnimplementedException here later to see when/how
// this is called, and implement properly.
PathRep canonicalizeNative(PathRep path) {
  return path;
}

/**
 * A Mock of the dart:io/process.dart Process class.
 */
abstract class Process {
  Future<int> exitCode;
  static Future<ProcessResult> run(
      String executable,
      List<String> arguments,
      {String workingDirectory,
       Map<String, String> environment,
       bool includeParentEnvironment: true,
       bool runInShell: false,
       Encoding stdoutEncoding,
       Encoding stderrEncoding}) {}
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  IOSink get stdin;
  bool kill([ProcessSignal signal = ProcessSignal.SIGTERM]);
}

/**
 * A Mock of the dart:io/process.dart ProcessSignal class.
 */
class ProcessSignal {
  static const ProcessSignal SIGTERM = const ProcessSignal._(15, "SIGTERM");
  final int _signalNumber;
  final String _name;
  const ProcessSignal._(this._signalNumber, this._name);
}
