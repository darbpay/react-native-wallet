import Foundation
import Security

/// Stores the Clerk session token (plus its expiry) in the keychain access
/// group shared between the host app and the extension.
///
/// The host app writes the token on login / refresh; the extension reads it to
/// authenticate the encrypt-endpoint call during provisioning. Token + expiry
/// are packed into a single keychain item so `status()` can judge validity
/// locally (no network) and still respect the <100ms budget.
///
/// Accessibility is `kSecAttrAccessibleAfterFirstUnlock` because the extension
/// may run while the device is locked (Wallet opened from the lock screen),
/// but the token never needs to be readable before first unlock after boot.
enum SharedKeychain {
  private static let account = "darbpay.wallet.clerk-session-token"

  private struct StoredToken: Codable {
    let token: String
    let expiresAt: Date
  }

  private static func baseQuery() -> [String: Any]? {
    guard let accessGroup = SharedAppGroup.identifier else { return nil }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: accessGroup,
    ]
  }

  /// Stores the Clerk session token and its absolute expiry. Overwrites any
  /// existing token. No-op (throws nothing meaningful) when the App Group is
  /// unconfigured.
  static func setAuthToken(_ token: String, expiresAt: Date) throws {
    guard var query = baseQuery() else { return }

    let payload = try JSONEncoder().encode(StoredToken(token: token, expiresAt: expiresAt))

    // Delete any existing item first so we don't have to branch add/update.
    SecItemDelete(query as CFDictionary)

    query[kSecValueData as String] = payload
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.unhandled(status: status)
    }
  }

  /// Returns the stored token and expiry, or nil if absent / unreadable.
  static func getAuthToken() -> (token: String, expiresAt: Date)? {
    guard var query = baseQuery() else { return nil }
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let data = item as? Data,
          let stored = try? JSONDecoder().decode(StoredToken.self, from: data) else {
      return nil
    }
    return (stored.token, stored.expiresAt)
  }

  /// True when a token exists and has not expired.
  static func isTokenValid(now: Date = Date()) -> Bool {
    guard let stored = getAuthToken() else { return false }
    return stored.expiresAt > now
  }

  /// Removes the stored token. Called on sign-out.
  static func clearAuthToken() {
    guard let query = baseQuery() else { return }
    SecItemDelete(query as CFDictionary)
  }

  enum KeychainError: Error {
    case unhandled(status: OSStatus)
  }
}
