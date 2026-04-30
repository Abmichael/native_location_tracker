/// Configuration for native-side HTTP upload of location batches.
///
/// Pass this to [BackgroundLocation.initialize] so the native platform
/// knows where to POST location batches and how to authenticate.
///
/// ## Payload format
///
/// The native uploader sends a JSON body to [uploadUrl]:
/// ```json
/// {
///   "points": [
///     { "lat": 9.01, "lng": 38.75, "timestamp": 1700000000000, ... }
///   ]
/// }
/// ```
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

  const UploadConfig({
    required this.uploadUrl,
    this.accessToken,
    this.refreshToken,
    this.refreshUrl,
    this.apiBaseUrl,
  });

  /// The Authorization header value.
  String? get authHeader =>
      accessToken != null ? 'Bearer $accessToken' : null;
}
