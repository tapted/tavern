
import 'dart:async';

Future<bool> get isInstalled => new Future.value(false);

Future<List<String>> run(List<String> args,
    {String workingDir, Map<String, String> environment}) {
  throw new Exception(
        'Git error. Command: git ${args.join(" ")}\n'
        'Can not run git in a platform app.');
}
