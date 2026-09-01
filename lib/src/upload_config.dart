import 'payload_format.dart';
import 'terminal_response.dart';

/// Configuration for native-side HTTP upload of location batches.
///
/// Pass this to [BackgroundLocation.initialize] so the native platform
/// knows where to POST location batches and how to authenticate.
///
/// ## Payload format
///
/// By default the native uploader sends this JSON body to [uploadUrl]:
/// ```json
/// {
///   "points": [
///     { "lat": 9.01, "lng": 38.75, "timestamp": 1700000000000, ... }
///   ]
/// }
/// ```
///
/// Pass [payload] to change the envelope, the field names, the time format,
/// the speed unit, or to add fixed root-level fields — see [PayloadFormat].
/// The default reproduces the body above exactly, so an existing integration
/// that does not set it sends what it always did.
///
/// ## Token refresh
///
/// If [refreshUrl] and [refreshToken] are provided, the native uploader
/// will attempt a token refresh on HTTP 401 by POSTing
/// `{ "refreshToken": "<token>" }` to [refreshUrl] and expecting back
/// `{ "accessToken": "...", "refreshToken": "..." }` (or wrapped in a
/// `"data"` object).
///
/// Set [refreshUrl] to `null` to disable native-side refresh (the app is
/// then responsible for calling [BackgroundLocation.setNativeAuthTokens]
/// whenever it refreshes tokens).
class UploadConfig {
  /// Full URL where location batches are POSTed.
  ///
  /// Example: `https://api.example.com/location/update`
  final String uploadUrl;

  /// Bearer access token (without the "Bearer " prefix — it will be added).
  final String? accessToken;

  /// Refresh token for native-side 401 recovery.
  final String? refreshToken;

  /// Full URL for token refresh (POST).
  ///
  /// Example: `https://api.example.com/auth/refresh`
  ///
  /// If null, native-side token refresh is disabled.
  final String? refreshUrl;

  /// Base URL of the API (used for auxiliary native-side calls).
  final String? apiBaseUrl;

  /// The shape of the uploaded JSON body.
  ///
  /// Defaults to the format this plugin has always sent, so leaving it out
  /// changes nothing.
  final PayloadFormat payload;

  /// Responses that mean "stop" rather than "try again later".
  ///
  /// Empty by default: without it every non-2xx is retried indefinitely, which
  /// is right for a tunnel and wrong for a trip that has ended. See
  /// [TerminalResponse].
  final TerminalResponse terminal;

  const UploadConfig({
    required this.uploadUrl,
    this.accessToken,
    this.refreshToken,
    this.refreshUrl,
    this.apiBaseUrl,
    this.payload = const PayloadFormat(),
    this.terminal = TerminalResponse.none,
  });

  /// The Authorization header value.
  String? get authHeader => accessToken != null ? 'Bearer $accessToken' : null;
}
