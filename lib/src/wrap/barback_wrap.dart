import '../version.dart';

// TODO(keertip): check how this is being used and whether specified
// constraints will work fine
final pubConstraints = {
  "barback": new VersionConstraint.parse(">=0.13.0 <0.16.0"),
  "source_span": new VersionConstraint.parse(">=1.0.0 <2.0.0"),
  "stack_trace": new VersionConstraint.parse(">=0.9.1 <2.0.0")
};

class TransformerId {

}

final supportedVersions = new VersionConstraint.parse(">=0.11.0 <0.13.0");
