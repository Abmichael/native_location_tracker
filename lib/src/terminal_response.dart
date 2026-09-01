/// Responses that mean "stop", rather than "try again later".
///
/// By default the uploader retries anything that is not a 2xx, which is right
/// for a tunnel, a flat battery on the server, or a phone that has wandered off
/// the network. It is wrong for an answer that will never change: a trip that
/// has ended, a link claimed by a different device, a token that has been
/// revoked. Without a way to tell those apart the uploader retries a permanent
/// refusal for as long as the app is installed, spending battery and data on a
/// request that cannot succeed.
///
/// Nothing is terminal unless the host app says so. The defaults are empty, so
/// an integration that does not configure this behaves exactly as before.
///
/// ## Statuses first, messages as a fallback
///
/// [statuses] is the mechanism to prefer: a status code is a contract, and it
/// is stable. [messages] exists for the case where the server cannot give the
/// permanent refusal a distinct code — most often because the natural code is
/// one the uploader must keep treating as retryable. `401` is the standard
/// example: it drives token refresh, so it cannot be made terminal wholesale,
/// even on an endpoint where nothing can be refreshed.
///
/// A message match is a heuristic and should be treated as one. It depends on
/// server copy that nobody has promised to keep stable, and it will stop
/// working silently the day that copy is reworded or translated. Use it to
/// cover a gap while a status code is agreed, not as the long-term answer.
class TerminalResponse {
  /// HTTP statuses that mean the upload will never succeed.
  ///
  /// Checked before the 401 refresh path, so a status listed here stops the
  /// uploader rather than spending a refresh on it first.
  final Set<int> statuses;

  /// Fragments that mark a response body as a permanent refusal.
  ///
  /// Matched case-insensitively, as substrings, against the response body —
  /// whatever the status was. Keep them specific: a fragment as short as
  /// `"not"` will match a body that says the opposite of what you meant.
  final List<String> messages;

  const TerminalResponse({this.statuses = const {}, this.messages = const []});

  /// Nothing is terminal — the behaviour before this existed.
  static const TerminalResponse none = TerminalResponse();

  bool get isEmpty => statuses.isEmpty && messages.isEmpty;

  Map<String, Object?> toMap() => {
    'statuses': statuses.toList(),
    'messages': messages,
  };
}
