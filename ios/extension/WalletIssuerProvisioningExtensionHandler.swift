import CoreGraphics
import Foundation
import PassKit

/// Base implementation of a `PKIssuerProvisioningExtension` handler, shipped in
/// the library so consumer apps only need a tiny brand subclass in their
/// extension target:
///
/// ```swift
/// import react_native_wallet
/// @objc(DarbProvisioningExtension)
/// class DarbProvisioningExtension: WalletIssuerProvisioningExtensionHandler {}
/// ```
///
/// All data comes from the App Group container the host app keeps fresh
/// (`EligibilityCache`) and the shared keychain (`SharedKeychain`). `status` and
/// `passEntries` never touch the network so they can answer within Apple's
/// ~100ms budget; only `generateAddPaymentPassRequest…` (which has a larger
/// budget) performs the encrypt round trip.
@available(iOS 14.0, *)
@objc open class WalletIssuerProvisioningExtensionHandler: PKIssuerProvisioningExtensionHandler {

  // MARK: - status (<100ms, no network)

  open override func status(completion: @escaping (PKIssuerProvisioningExtensionStatus) -> Void) {
    let result = PKIssuerProvisioningExtensionStatus()
    result.passEntriesAvailable = false
    result.remotePassEntriesAvailable = false
    result.requiresAuthentication = false

    // Missing or stale cache → ask Wallet to show "Open DarbPay to add this card".
    guard let file = EligibilityCache.read(), EligibilityCache.isFresh(file) else {
      result.requiresAuthentication = true
      completion(result)
      return
    }

    // No / expired Clerk token → user must re-auth in the app.
    guard SharedKeychain.isTokenValid() else {
      result.requiresAuthentication = true
      completion(result)
      return
    }

    let library = PKPassLibrary()
    let localProvisioned = provisionedIdentifiers(library, remote: false)
    let remoteProvisioned = provisionedIdentifiers(library, remote: true)

    result.passEntriesAvailable = file.cards.contains { isEligible($0, excluding: localProvisioned) }
    result.remotePassEntriesAvailable = file.cards.contains { isEligible($0, excluding: remoteProvisioned) }
    completion(result)
  }

  // MARK: - entries (<100ms, no network)

  open override func passEntries(completion: @escaping ([PKIssuerProvisioningExtensionPassEntry]) -> Void) {
    completion(buildEntries(remote: false))
  }

  open override func remotePassEntries(completion: @escaping ([PKIssuerProvisioningExtensionPassEntry]) -> Void) {
    completion(buildEntries(remote: true))
  }

  // MARK: - generate request (larger budget, performs network)

  open override func generateAddPaymentPassRequestForPassEntryWithIdentifier(
    _ identifier: String,
    configuration: PKAddPaymentPassRequestConfiguration,
    certificateChain certificates: [Data],
    nonce: Data,
    nonceSignature: Data,
    completionHandler completion: @escaping (PKAddPaymentPassRequest?) -> Void
  ) {
    // `identifier` is the DarbPay cardId we set on the entry.
    let request = ProvisioningRequest(
      cardId: identifier,
      nonce: nonce,
      nonceSignature: nonceSignature,
      certificates: certificates
    )
    WalletProvisioningClient.encrypt(request) { result in
      switch result {
      case .failure:
        // Returning nil makes PassKit show the user a retry / cancel dialog.
        completion(nil)
      case .success(let response):
        let addRequest = PKAddPaymentPassRequest()
        addRequest.encryptedPassData = response.encryptedPassData
        addRequest.activationData = response.activationData
        addRequest.ephemeralPublicKey = response.ephemeralPublicKey
        completion(addRequest)
      }
    }
  }

  // MARK: - Helpers

  /// Dedup uses `panId` (Apple's primaryAccountIdentifier); the entry
  /// identifier is `cardId`. A card with no `panId` has never been provisioned
  /// and is therefore always eligible.
  private func isEligible(_ card: EligibilityCard, excluding provisioned: Set<String>) -> Bool {
    guard let panId = card.panId else { return true }
    return !provisioned.contains(panId)
  }

  private func provisionedIdentifiers(_ library: PKPassLibrary, remote: Bool) -> Set<String> {
    if remote {
      return Set(library.remoteSecureElementPasses.compactMap { $0.primaryAccountIdentifier })
    }
    return Set(library.passes(of: .payment).compactMap { $0.secureElementPass?.primaryAccountIdentifier })
  }

  private func buildEntries(remote: Bool) -> [PKIssuerProvisioningExtensionPaymentPassEntry] {
    guard let file = EligibilityCache.read(),
          EligibilityCache.isFresh(file),
          SharedKeychain.isTokenValid() else {
      return []
    }

    let library = PKPassLibrary()
    let exclude = provisionedIdentifiers(library, remote: remote)

    return file.cards.compactMap { card -> PKIssuerProvisioningExtensionPaymentPassEntry? in
      guard isEligible(card, excluding: exclude),
            let configuration = PKAddPaymentPassRequestConfiguration(encryptionScheme: .ECC_V2) else {
        return nil
      }
      configuration.cardholderName = card.cardholderName
      configuration.primaryAccountSuffix = card.last4
      configuration.localizedDescription = card.displayName
      if let network = PaymentNetworkMapper.paymentNetwork(from: card.network) {
        configuration.paymentNetwork = network
      }

      let art = EligibilityCache.cardArtImage(cardId: card.cardId) ?? Self.placeholderArt()
      return PKIssuerProvisioningExtensionPaymentPassEntry(
        identifier: card.cardId,
        title: card.displayName,
        art: art,
        addRequestConfiguration: configuration
      )
    }
  }

  /// A 1×1 transparent image used only when no card-art thumbnail is cached.
  /// The entry initializer requires a non-nil CGImage; this keeps the card
  /// visible rather than dropping it.
  private static func placeholderArt() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage() ?? Self.fallbackImage
  }

  // Last-resort 1×1 image built from raw bytes; only reached if CGContext
  // creation itself fails (effectively never).
  private static let fallbackImage: CGImage = {
    let pixel: [UInt8] = [0, 0, 0, 0]
    let provider = CGDataProvider(data: Data(pixel) as CFData)!
    return CGImage(
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }()
}
