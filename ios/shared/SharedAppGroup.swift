import Foundation

/// Resolves the App Group container shared between the host app and the
/// PKIssuerProvisioningExtension app-extension.
///
/// The App Group identifier is supplied by the consumer app through the
/// `WalletExtensionAppGroup` key in its (and the extension's) Info.plist —
/// written by the Expo config plugin at prebuild time. When the key is absent
/// (extension feature not configured), every accessor returns nil and the
/// cache/keychain helpers become no-ops, so the library stays backward
/// compatible.
enum SharedAppGroup {
  /// Info.plist key the consumer app / extension declare the App Group under.
  static let infoPlistKey = "WalletExtensionAppGroup"

  /// The configured App Group identifier, e.g. "group.com.darbpay.mobile".
  static var identifier: String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
          !value.isEmpty else {
      return nil
    }
    return value
  }

  /// The shared container URL, or nil if the App Group is unconfigured /
  /// the entitlement is missing.
  static var containerURL: URL? {
    guard let identifier else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }
}
