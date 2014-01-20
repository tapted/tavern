library pub.sdk_wrap;

import '../pubspec.dart';
import '../version.dart';

/// Determine the SDK's version number.
Version getVersion() => null;

/// Ensures that if [pubspec] has an SDK constraint, then it is compatible
/// with the current SDK. Throws a [SolveFailure] if not.
void validateSdkConstraint(Pubspec pubspec) {}