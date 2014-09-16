import '../version.dart';

final pubConstraints = {
  "barback": new VersionConstraint.parse(">=0.13.0 <0.15.3"),
  "source_span": new VersionConstraint.parse(">=1.0.0 <2.0.0"),
  "stack_trace": new VersionConstraint.parse(">=0.9.1 <2.0.0")
};

class TransformerId {

}

final supportedVersions = new VersionConstraint.parse(">=0.11.0 <0.13.0");
