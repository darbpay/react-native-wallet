import CoreGraphics
import Foundation
import os.log
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

  // Subsystem is the extension's bundle id at runtime so Console.app can filter
  // by either `com.darbpay.mobile.walletextension` (production) or whatever the
  // consumer named the target.
  private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "react-native-wallet-extension", category: "status")

  // MARK: - status (<100ms, no network)

  open override func status(completion: @escaping (PKIssuerProvisioningExtensionStatus) -> Void) {
    let result = PKIssuerProvisioningExtensionStatus()
    result.passEntriesAvailable = false
    result.remotePassEntriesAvailable = false
    result.requiresAuthentication = false

    os_log("status() entered", log: Self.log, type: .default)

    // No cache yet (user has never logged into the host app, or cache went
    // stale past the 30-day budget). Wallet falls back to the "Open <App> to
    // add this card" outcome (cert PROPBM19 outcome 2).
    guard let file = EligibilityCache.read(), EligibilityCache.isFresh(file) else {
      os_log("status() → requiresAuthentication=true (no/stale cache)", log: Self.log, type: .default)
      result.requiresAuthentication = true
      completion(result)
      return
    }

    // Cache is fresh. Compute passEntriesAvailable from the cached cards
    // REGARDLESS of token validity — Apple's documented design (DEV-4.0 §10.2
    // FAQ p.90: "The user needs to log in to the app at least once to update
    // the extension with card status…") is for status() to keep surfacing the
    // available cards even when the user signs out, so Wallet shows the
    // issuer and invokes the UI extension (`PKIssuerProvisioningExtension
    // AuthorizationProviding`) for inline re-auth. Returning passEntries=false
    // here on token expiry hides the issuer entirely (PROPBM19 outcome-2
    // fallback) — which used to be acceptable when we only shipped the non-UI
    // extension, but now defeats the purpose of bundling the UI extension.
    let library = PKPassLibrary()
    let localProvisioned = provisionedIdentifiers(library, remote: false)
    let remoteProvisioned = provisionedIdentifiers(library, remote: true)
    result.passEntriesAvailable = file.cards.contains { isEligible($0, excluding: localProvisioned) }
    result.remotePassEntriesAvailable = file.cards.contains { isEligible($0, excluding: remoteProvisioned) }

    // Token expired or missing → UI extension must re-auth before
    // generateAddPaymentPassRequest can call the encrypt endpoint with a
    // valid Bearer. Wallet sees passEntries=true AND requiresAuth=true and
    // routes the tap through the UI extension first, then re-polls
    // passEntries() with a fresh token in the keychain.
    if !SharedKeychain.isTokenValid() {
      result.requiresAuthentication = true
      os_log("status() → passEntries=%{public}d remotePass=%{public}d requiresAuth=true (invalid token; %{public}d cached cards)", log: Self.log, type: .default, result.passEntriesAvailable ? 1 : 0, result.remotePassEntriesAvailable ? 1 : 0, file.cards.count)
    } else {
      os_log("status() → passEntries=%{public}d remotePass=%{public}d cardCount=%{public}d", log: Self.log, type: .default, result.passEntriesAvailable ? 1 : 0, result.remotePassEntriesAvailable ? 1 : 0, file.cards.count)
    }
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
      // `paymentNetwork` is intentionally NOT set here — match the in-app
      // `PKAddPaymentPassViewController` flow exactly, which sets only the
      // three fields above. Apple's tokenization service treats
      // `configuration.paymentNetwork` as a contract that must match the
      // encrypted payload; asserting it and getting it wrong (or having any
      // mismatch with what the issuer registered) triggers the user-facing
      // "Card Not Added — Contact your card issuer for more information"
      // error at activation time. Letting PassKit infer the network from
      // the encrypted payload is the safer default.

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
