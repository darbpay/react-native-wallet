import Foundation

/// Input for an encrypt-endpoint round trip, built from the values Apple hands
/// to `generateAddPaymentPassRequestForPassEntryWithIdentifier`.
struct ProvisioningRequest {
  /// DarbPay card id — becomes the `{cardId}` path segment of the encrypt URL.
  let cardId: String
  let nonce: Data
  let nonceSignature: Data
  let certificates: [Data]
}

/// The encrypted material the issuer backend returns, fed straight into a
/// `PKAddPaymentPassRequest`.
struct ProvisioningResponse {
  let encryptedPassData: Data
  let activationData: Data
  let ephemeralPublicKey: Data
}

enum ProvisioningError: Error {
  case missingConfig
  case missingToken
  case network(Error)
  case badResponse(Int)
  case decode
}

/// Calls the issuer encrypt endpoint from within the app-extension (which has
/// no React Native runtime, so it cannot reuse the JS issuer callback the
/// in-app flow uses). This is the extension's ONLY consumer — the in-app
/// `WalletManager` flow is deliberately left untouched.
///
/// Configuration comes from the extension's Info.plist:
///  - `WalletExtensionEncryptBaseUrl` — e.g. "https://api.darbpay.com/api/employee"
/// The full URL is `{base}/cards/{cardId}/apple-pay/encrypt`.
/// Auth is the Clerk session token read from the shared keychain.
///
/// Wire format matches the in-app Green Path (see `hooks/use-apple-pay.ts` in
/// the consumer app):
///  - Request: `nonce` and `nonceSignature` are HEX strings; `certificates`
///    are base64 strings.
///  - Response: `{ encryptedPassData, wrappedKey, activationCode }`, all
///    base64 strings. `wrappedKey` maps to PassKit's `ephemeralPublicKey` and
///    `activationCode` maps to `activationData`.
enum WalletProvisioningClient {
  static let encryptBaseUrlKey = "WalletExtensionEncryptBaseUrl"
  private static let requestTimeout: TimeInterval = 30

  /// Request body — field names must match the encrypt endpoint contract
  /// (the same backend the in-app Green Path posts to).
  private struct RequestBody: Encodable {
    let nonce: String           // hex
    let nonceSignature: String  // hex
    let certificates: [String]  // base64
  }

  private struct ResponseBody: Decodable {
    let encryptedPassData: String  // base64
    let wrappedKey: String         // base64 — maps to PassKit ephemeralPublicKey
    let activationCode: String     // base64 — maps to PassKit activationData
  }

  static func encrypt(
    _ request: ProvisioningRequest,
    completion: @escaping (Result<ProvisioningResponse, ProvisioningError>) -> Void
  ) {
    guard let base = Bundle.main.object(forInfoDictionaryKey: encryptBaseUrlKey) as? String,
          !base.isEmpty,
          let url = URL(string: "\(base)/cards/\(request.cardId)/apple-pay/encrypt") else {
      completion(.failure(.missingConfig))
      return
    }

    guard let stored = SharedKeychain.getAuthToken() else {
      completion(.failure(.missingToken))
      return
    }

    let body = RequestBody(
      nonce: request.nonce.hexEncodedString(),
      nonceSignature: request.nonceSignature.hexEncodedString(),
      certificates: request.certificates.map { $0.base64EncodedString() }
    )

    var urlRequest = URLRequest(url: url, timeoutInterval: requestTimeout)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(stored.token)", forHTTPHeaderField: "Authorization")

    do {
      urlRequest.httpBody = try JSONEncoder().encode(body)
    } catch {
      completion(.failure(.decode))
      return
    }

    URLSession.shared.dataTask(with: urlRequest) { data, response, error in
      if let error {
        completion(.failure(.network(error)))
        return
      }
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200...299).contains(statusCode) else {
        completion(.failure(.badResponse(statusCode)))
        return
      }
      guard let data,
            let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
            let encryptedPassData = Data(base64Encoded: decoded.encryptedPassData, options: .ignoreUnknownCharacters),
            let activationData = Data(base64Encoded: decoded.activationCode, options: .ignoreUnknownCharacters),
            let ephemeralPublicKey = Data(base64Encoded: decoded.wrappedKey, options: .ignoreUnknownCharacters) else {
        completion(.failure(.decode))
        return
      }
      completion(.success(ProvisioningResponse(
        encryptedPassData: encryptedPassData,
        activationData: activationData,
        ephemeralPublicKey: ephemeralPublicKey
      )))
    }.resume()
  }
}

private extension Data {
  func hexEncodedString() -> String {
    map { String(format: "%02x", $0) }.joined()
  }
}
