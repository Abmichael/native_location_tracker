import 'package:flutter_test/flutter_test.dart';
import 'package:native_location_tracker/native_location_tracker.dart';

/// The map crosses to native and is persisted there, so what matters is that
/// it is complete and that the default stays "nothing is terminal" — an
/// integration that has not opted in must keep retrying exactly as before.
void main() {
  group('TerminalResponse', () {
    test('nothing is terminal by default', () {
      const terminal = TerminalResponse.none;

      expect(terminal.isEmpty, isTrue);
      expect(terminal.toMap(), {'statuses': <int>[], 'messages': <String>[]});
    });

    test('an UploadConfig with no terminal set keeps the old behaviour', () {
      const config = UploadConfig(uploadUrl: 'https://example.com/points');

      expect(config.terminal.isEmpty, isTrue);
    });

    test('statuses cross as a list', () {
      const terminal = TerminalResponse(statuses: {409, 410});

      expect(terminal.toMap()['statuses'], containsAll([409, 410]));
      expect(terminal.isEmpty, isFalse);
    });

    test('messages cross in the order given', () {
      const terminal = TerminalResponse(
        messages: ['unknown link', 'trip is over'],
      );

      expect(terminal.toMap()['messages'], ['unknown link', 'trip is over']);
      expect(terminal.isEmpty, isFalse);
    });

    test('either one alone is enough to be non-empty', () {
      expect(const TerminalResponse(statuses: {410}).isEmpty, isFalse);
      expect(const TerminalResponse(messages: ['gone']).isEmpty, isFalse);
    });

    test('the combination a session-token API needs', () {
      // Statuses for the codes that are unambiguous, and a message for the one
      // that cannot be made terminal wholesale — 401 drives token refresh.
      const terminal = TerminalResponse(
        statuses: {409, 410},
        messages: ['unknown link'],
      );

      final map = terminal.toMap();
      expect(map['statuses'], containsAll([409, 410]));
      expect(map['messages'], ['unknown link']);
    });
  });
}
