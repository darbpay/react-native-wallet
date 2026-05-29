import PassKit

/// Single source of truth for mapping a network identifier string (as sent by
/// JS / stored in the eligibility cache) to a `PKPaymentNetwork`.
///
/// Lives in `ios/shared/` so it can be linked into BOTH the React Native module
/// (`Core` subspec, via `CardInfo`) and the app-extension (`WalletExtension`
/// subspec, via the provisioning handler). Keep this the only place that knows
/// the string → `PKPaymentNetwork` mapping.
enum PaymentNetworkMapper {
  static func paymentNetwork(from identifier: String) -> PKPaymentNetwork? {
    switch identifier.lowercased() {
    case "visa": return .visa
    case "mastercard": return .masterCard
    case "amex": return .amex
    case "discover": return .discover
    default: return nil
    }
  }
}
