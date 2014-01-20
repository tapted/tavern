library pub.pathrep;

import 'package:path/path.dart' as path;

/// A class which stores a representation of a path on the filsystem.
class PathRep {
  String _filename;

  PathRep(String filename) : _filename = filename {}

  String get name => path.basename(_filename);
  String get basename => path.basename(_filename);
  String get fullPath => _filename;
  PathRep get dirname => new PathRep(path.dirname(_filename));

  String toString() => _filename;
  Uri toUri() => path.toUri(_filename);
  bool inPackages() => path.split(_filename).contains("packages");
  List<String> split() => path.split(_filename);

  PathRep join(part1, [part2, part3, part4, part5, part6, part7]) {
    return new PathRep(path.join(_filename, part1, part2, part3, part4, part5,
        part6, part7));
  }

  PathRep relativeTo(PathRep from) {
    return new PathRep(path.relative(_filename, from: from.fullPath));
  }
}