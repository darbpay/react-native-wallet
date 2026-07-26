import Foundation
import os.log

/// Minimal Clerk Frontend API (FAPI) client for the Wallet auth UI extension.
///
/// The extension can't link the Clerk SDK (no React Native runtime), so it
/// talks to Clerk's Frontend API directly over HTTPS to run the same phone +
/// OTP sign-in the host app does with `useSignIn` (`signIn.create` →
/// `prepareFirstFactor` → `attemptFirstFactor`), then mints a JWT-template
/// token and hands it to `SharedKeychain`.
///
/// Native-client handshake (per Clerk's "Making authenticated requests" doc):
/// the first request sends an empty `Authorization` header; FAPI returns a
/// short-lived **client JWT** in the `Authorization` response header which we
/// resend on every subsequent request. That client JWT is what threads the
/// sign-in + session state together (no cookies).
///
/// Reference-typed because the client JWT mutates across the call sequence and
/// is shared by one VC's flow.
@available(iOS 14.0, *)
final class ClerkFrontendClient {

  /// First entry of Clerk's `errors[]` envelope. Captured verbatim so the
  /// view-controller's `mapClerkError` can pattern-match on `code` / `message`
  /// exactly like the host RN app's `use-login-flow.ts`.
  struct ClerkApiError {
    let code: String?
    let message: String?
    let longMessage: String?
  }

  enum ClerkError: LocalizedError {
    case notConfigured
    case network(Error)
    /// 4xx/5xx response from Clerk. `status` is the HTTP code; `api` is the
    /// parsed first entry of `errors[]` (nil iff the body wasn't a Clerk
    /// envelope at all).
    case api(ClerkApiError?, status: Int)
    case parse
    case noPhoneFactor
    case signInIncomplete(status: String)

    var errorDescription: String? {
      switch self {
      case .notConfigured: return "Sign-in is not configured."
      case .network(let e): return e.localizedDescription
      case .api(let api, _):
        return api?.longMessage ?? api?.message ?? "Something went wrong. Please try again."
      case .parse: return "Unexpected response. Please try again."
      case .noPhoneFactor: return "This number can't sign in by SMS."
      case .signInIncomplete: return "Couldn't complete sign-in. Please try again."
      }
    }
  }

  struct PreparedSignIn {
    let signInId: String
    /// Present when the account offers `phone_code` as a first factor. Absent
    /// for MFA-reserved phones (Clerk excludes phone_code from first factors
    /// when the phone serves as factor two — DARB-427).
    let phoneNumberId: String?
    let safeIdentifier: String?
    /// True when the account has a password first factor. Mirrors the host
    /// app's flow: password accounts sign in with it; passwordless accounts
    /// must complete setup in the app (the inline sheet doesn't replicate the
    /// OTP-verified set-password flow).
    let hasPasswordFactor: Bool
  }

  /// Outcome of a password first-factor attempt.
  enum PasswordAttemptResult {
    case complete(sessionId: String)
    case needsSecondFactor
  }

  struct MintedToken {
    let jwt: String
    let expiresAt: Date
  }

  private static let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "react-native-wallet-extension-auth",
    category: "clerk"
  )

  private static let publishableKeyInfoPlistKey = "WalletExtensionClerkPublishableKey"
  private static let jwtTemplateInfoPlistKey = "WalletExtensionJwtTemplate"

  /// Short-lived client JWT from the previous FAPI response. Empty on the first
  /// request (which is how FAPI knows to mint a fresh client).
  private var clientToken: String = ""

  private let session = URLSession(configuration: .ephemeral)

  // MARK: - Config

  /// True when a publishable key is present so the inline flow can run.
  static var isConfigured: Bool { fapiBaseURL() != nil }

  /// The JWT template name the host app expects in the shared keychain.
  static var jwtTemplate: String {
    (Bundle.main.object(forInfoDictionaryKey: jwtTemplateInfoPlistKey) as? String).flatMap {
      $0.isEmpty ? nil : $0
    } ?? "wallet_extension"
  }

  /// Derives the Frontend API base URL from the publishable key. A Clerk
  /// publishable key is `pk_(test|live)_<base64(host + "$")>`.
  static func fapiBaseURL() -> URL? {
    guard let pk = Bundle.main.object(forInfoDictionaryKey: publishableKeyInfoPlistKey) as? String,
          !pk.isEmpty else {
      return nil
    }
    var encoded = pk
      .replacingOccurrences(of: "pk_test_", with: "")
      .replacingOccurrences(of: "pk_live_", with: "")
    // Clerk publishable keys ship without the trailing `=` padding; Swift's
    // `Data(base64Encoded:)` is strict and returns nil for unpadded input.
    // Pad up to the next multiple of 4 before decoding.
    while encoded.count % 4 != 0 { encoded.append("=") }
    guard let data = Data(base64Encoded: encoded),
          var host = String(data: data, encoding: .utf8) else {
      return nil
    }
    if host.hasSuffix("$") { host.removeLast() }
    guard !host.isEmpty else { return nil }
    return URL(string: "https://\(host)")
  }

  // MARK: - Sign-in flow

  /// `signIn.create({ identifier })` — starts a sign-in and inspects the
  /// supported first factors (password / phone_code).
  func createSignIn(identifier: String) async throws -> PreparedSignIn {
    let json = try await post(path: "client/sign_ins", form: ["identifier": identifier])
    let response = (json["response"] as? [String: Any]) ?? json
    guard let signInId = response["id"] as? String else { throw ClerkError.parse }

    let factors = (response["supported_first_factors"] as? [[String: Any]]) ?? []
    let hasPassword = factors.contains { ($0["strategy"] as? String) == "password" }
    let phone = factors.first(where: { ($0["strategy"] as? String) == "phone_code" })
    return PreparedSignIn(
      signInId: signInId,
      phoneNumberId: phone?["phone_number_id"] as? String,
      safeIdentifier: phone?["safe_identifier"] as? String,
      hasPasswordFactor: hasPassword
    )
  }

  /// `signIn.prepareFirstFactor({ strategy: 'phone_code', phoneNumberId })` —
  /// sends the OTP SMS.
  func prepareFirstFactor(signInId: String, phoneNumberId: String) async throws {
    _ = try await post(
      path: "client/sign_ins/\(signInId)/prepare_first_factor",
      form: ["strategy": "phone_code", "phone_number_id": phoneNumberId]
    )
  }

  /// `signIn.attemptFirstFactor({ strategy: 'phone_code', code })` — verifies
  /// the OTP. Returns the created session id.
  func attemptFirstFactor(signInId: String, code: String) async throws -> String {
    let json = try await post(
      path: "client/sign_ins/\(signInId)/attempt_first_factor",
      form: ["strategy": "phone_code", "code": code]
    )
    let response = (json["response"] as? [String: Any]) ?? json
    let status = response["status"] as? String ?? "unknown"
    guard status == "complete" else { throw ClerkError.signInIncomplete(status: status) }
    guard let sessionId = response["created_session_id"] as? String else { throw ClerkError.parse }
    return sessionId
  }

  /// `signIn.attemptFirstFactor({ strategy: 'password', password })` — the
  /// primary sign-in path since the app made passwords mandatory. `complete`
  /// yields a session; `needs_second_factor` means the account has phone MFA
  /// and the caller must run prepare/attemptSecondFactor next.
  func attemptPassword(signInId: String, password: String) async throws -> PasswordAttemptResult {
    let json = try await post(
      path: "client/sign_ins/\(signInId)/attempt_first_factor",
      form: ["strategy": "password", "password": password]
    )
    let response = (json["response"] as? [String: Any]) ?? json
    let status = response["status"] as? String ?? "unknown"
    switch status {
    case "complete":
      guard let sessionId = response["created_session_id"] as? String else { throw ClerkError.parse }
      return .complete(sessionId: sessionId)
    case "needs_second_factor":
      return .needsSecondFactor
    default:
      throw ClerkError.signInIncomplete(status: status)
    }
  }

  /// `signIn.prepareSecondFactor({ strategy: 'phone_code' })` — sends the MFA
  /// SMS after a successful password attempt.
  func prepareSecondFactor(signInId: String) async throws {
    _ = try await post(
      path: "client/sign_ins/\(signInId)/prepare_second_factor",
      form: ["strategy": "phone_code"]
    )
  }

  /// `signIn.attemptSecondFactor({ strategy: 'phone_code', code })` — verifies
  /// the MFA OTP. Returns the created session id.
  func attemptSecondFactor(signInId: String, code: String) async throws -> String {
    let json = try await post(
      path: "client/sign_ins/\(signInId)/attempt_second_factor",
      form: ["strategy": "phone_code", "code": code]
    )
    let response = (json["response"] as? [String: Any]) ?? json
    let status = response["status"] as? String ?? "unknown"
    guard status == "complete" else { throw ClerkError.signInIncomplete(status: status) }
    guard let sessionId = response["created_session_id"] as? String else { throw ClerkError.parse }
    return sessionId
  }

  /// `GET /v1/me` — the signed-in user's display name, used as the cardholder
  /// fallback when a card carries no embossing name. Best-effort: callers
  /// treat nil/throw as "no fallback available".
  func fetchUserFullName() async throws -> String? {
    let json = try await request(method: "GET", path: "me", form: [:])
    let response = (json["response"] as? [String: Any]) ?? json
    let first = (response["first_name"] as? String) ?? ""
    let last = (response["last_name"] as? String) ?? ""
    let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    return full.isEmpty ? nil : full
  }

  /// Mints the JWT-template token for the session and decodes its expiry.
  func mintToken(sessionId: String) async throws -> MintedToken {
    let json = try await post(
      path: "client/sessions/\(sessionId)/tokens/\(Self.jwtTemplate)",
      form: [:]
    )
    let jwt = (json["jwt"] as? String)
      ?? ((json["response"] as? [String: Any])?["jwt"] as? String)
    guard let token = jwt, !token.isEmpty else { throw ClerkError.parse }
    let expiresAt = Self.decodeExp(token) ?? Date().addingTimeInterval(60 * 25)
    return MintedToken(jwt: token, expiresAt: expiresAt)
  }

  // MARK: - HTTP

  private func post(path: String, form: [String: String]) async throws -> [String: Any] {
    try await request(method: "POST", path: path, form: form)
  }

  private func request(method: String, path: String, form: [String: String]) async throws -> [String: Any] {
    guard let base = Self.fapiBaseURL() else { throw ClerkError.notConfigured }

    var comps = URLComponents(
      url: base.appendingPathComponent("v1").appendingPathComponent(path),
      resolvingAgainstBaseURL: false
    )!
    // `_is_native=1` switches FAPI to header-based (cookieless) client auth;
    // `_clerk_js_version` is required by FAPI request validation.
    comps.queryItems = [
      URLQueryItem(name: "_is_native", value: "1"),
      URLQueryItem(name: "_clerk_js_version", value: "5"),
    ]

    var request = URLRequest(url: comps.url!)
    request.httpMethod = method
    // Empty on the first call; the captured client JWT thereafter.
    request.setValue(clientToken, forHTTPHeaderField: "Authorization")
    if method != "GET" {
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Self.formEncode(form).data(using: .utf8)
    }

    let data: Data
    let response: URLResponse
    do {
      // Continuation wrapper instead of `URLSession.data(for:)` (iOS 15+) so
      // the flow runs on the extension's iOS 14 deployment target.
      (data, response) = try await dataTask(for: request)
    } catch {
      throw ClerkError.network(error)
    }

    // Capture the rotated client JWT for subsequent requests.
    if let http = response as? HTTPURLResponse,
       let auth = http.value(forHTTPHeaderField: "Authorization"), !auth.isEmpty {
      clientToken = auth
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      os_log("FAPI %{public}@ → status=%d, unparseable body", log: Self.log, type: .error, path, status)
      throw status == 0 ? ClerkError.parse : ClerkError.api(nil, status: status)
    }

    guard (200..<300).contains(status) else {
      let api = Self.firstClerkApiError(json)
      os_log(
        "FAPI %{public}@ → status=%d, code=%{public}@, msg=%{public}@",
        log: Self.log, type: .error, path, status, api?.code ?? "?", api?.message ?? "?"
      )
      throw ClerkError.api(api, status: status)
    }
    return json
  }

  /// iOS 14-compatible async wrapper around `URLSession.dataTask`.
  private func dataTask(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await withCheckedThrowingContinuation { continuation in
      session.dataTask(with: request) { data, response, error in
        if let error = error {
          continuation.resume(throwing: error)
          return
        }
        guard let data = data, let response = response else {
          continuation.resume(throwing: ClerkError.parse)
          return
        }
        continuation.resume(returning: (data, response))
      }.resume()
    }
  }

  // MARK: - Helpers

  /// Clerk error envelope: `{ "errors": [{ "message", "long_message", "code" }] }`.
  private static func firstClerkApiError(_ json: [String: Any]) -> ClerkApiError? {
    guard let errors = json["errors"] as? [[String: Any]], let first = errors.first else { return nil }
    return ClerkApiError(
      code: first["code"] as? String,
      message: first["message"] as? String,
      longMessage: first["long_message"] as? String
    )
  }

  /// Percent-encodes form values strictly (so `+` in phone numbers becomes
  /// `%2B`, not a space).
  private static func formEncode(_ form: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return form.map { key, value in
      let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(k)=\(v)"
    }.joined(separator: "&")
  }

  /// Decodes the `exp` claim (seconds since epoch) from a JWT.
  private static func decodeExp(_ jwt: String) -> Date? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload.append("=") }
    guard let data = Data(base64Encoded: payload),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = obj["exp"] as? Double else {
      return nil
    }
    return Date(timeIntervalSince1970: exp)
  }
}
