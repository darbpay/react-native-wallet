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

    // Build marker: proves which handler generation is actually installed —
    // if Console.app doesn't show "gen2", the extension target wasn't rebuilt.
    os_log("status() entered (gen6 hide-once-in-wallet)", log: Self.log, type: .default)

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
    //
    // Eligibility is decided against the LIVE pass library (panId, with a
    // last4-suffix fallback for cards whose panId hasn't reached the cache) —
    // never against a write-time snapshot. When every cached card is already
    // provisioned on both surfaces, both flags come back false and Wallet
    // removes the issuer row entirely (Apple: "all cards are already
    // provisioned" → hidden).
    let library = PKPassLibrary()
    let localEligible = eligibleCards(file.cards, in: library, remote: false)
    let remoteEligible = eligibleCards(file.cards, in: library, remote: true)
    result.passEntriesAvailable = !localEligible.isEmpty
    result.remotePassEntriesAvailable = !remoteEligible.isEmpty

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
        // Our own pass-library read returns empty in the appex (no App-ID
        // visibility), so we'd keep offering this card after Wallet adds it.
        // Record the add here so status()/passEntries() exclude it until the
        // app's next sync rewrites the cache with fresh flags. Slight
        // over-suppression if the user cancels after this point — corrected
        // on the next app open, and retry-from-the-dialog is unaffected.
        EligibilityCache.markProvisioned(cardId: identifier)
        os_log("generate() succeeded → marked cardId=%{public}@ provisioned", log: Self.log, type: .default, identifier)
        let addRequest = PKAddPaymentPassRequest()
        addRequest.encryptedPassData = response.encryptedPassData
        addRequest.activationData = response.activationData
        addRequest.ephemeralPublicKey = response.ephemeralPublicKey
        completion(addRequest)
      }
    }
  }

  // MARK: - Helpers

  /// The cached cards still eligible for the given surface, decided against
  /// the live pass library at call time. Dedup is `panId` first (exact), then
  /// a collision-guarded `last4`-suffix fallback for cards whose `panId`
  /// hasn't reached the cache yet — the decision itself lives in
  /// `ProvisioningEligibility` so it stays unit-testable without PassKit.
  /// Grace window after an extension-side encrypt success during which an
  /// unconfirmed marker still hides the card even with an authoritative
  /// library — the pass takes a few moments (longer on yellow-path
  /// activation) to land in the library after Wallet commits it.
  private static let markerGraceSeconds: TimeInterval = 10 * 60

  private func eligibleCards(_ cards: [EligibilityCard], in library: PKPassLibrary, remote: Bool) -> [EligibilityCard] {
    // passes() + secureElementPass — the exact call the host app's
    // WalletManager uses and is proven to return payment passes. The
    // deprecated passes(of: .payment) filter returned [] in the appex
    // context even with entitlements in place.
    let localPasses = library.passes().compactMap { $0.secureElementPass }
    let remotePasses = remote ? library.remoteSecureElementPasses : []
    // The remote (Watch) surface dedupes against the UNION of iPhone + Watch
    // passes: once a card is anywhere in Apple Wallet, the issuer entry
    // disappears entirely (product decision). Watch provisioning for an
    // iPhone-resident card is served by Wallet's native "cards on your
    // iPhone" mirror flow and the in-app Add-to-Watch button, not by this
    // extension. A card on neither device stays listed on both surfaces, so
    // provisioning a brand-new card straight to the Watch still works.
    let passes = localPasses + remotePasses
    let panIds = Set(passes.compactMap { $0.primaryAccountIdentifier })
    let suffixes = Set(passes.map { ProvisioningEligibility.normalizedSuffix($0.primaryAccountNumberSuffix) })

    // Once a surface has proven readable, remember it: from then on an empty
    // read on that surface means "genuinely empty wallet" (live authority)
    // rather than "no library access" (flags fallback) — this is what makes
    // removing the LAST card re-offer it instead of trusting stale flags.
    if !localPasses.isEmpty {
      EligibilityCache.recordLiveLibrarySeen(remote: false)
    }
    if !remotePasses.isEmpty {
      EligibilityCache.recordLiveLibrarySeen(remote: true)
    }
    let authoritative = !passes.isEmpty
      || EligibilityCache.isLiveLibraryTrusted(remote: false)
      || (remote && EligibilityCache.isLiveLibraryTrusted(remote: true))

    // Just-provisioned markers (extension-side adds the app hasn't synced
    // yet). With an authoritative library the marker is only a short bridge:
    // confirmed by a live pass → drop it, the live dedup below takes over;
    // still unconfirmed past the grace window → the add never completed or
    // the pass was removed again → drop it and re-offer the card. Without
    // library access the marker is the only signal and keeps hiding the card
    // until the app's next sync or the marker TTL.
    var last4Counts: [String: Int] = [:]
    for card in cards { last4Counts[card.last4, default: 0] += 1 }
    let markers = EligibilityCache.provisionedMarkers()
    let now = Date()
    let cards = cards.filter { card in
      guard let markedAt = markers[card.cardId] else { return true }
      guard authoritative else {
        os_log("eligibility(remote=%{public}d): card last4=%{public}@ excluded (marker, library blind)", log: Self.log, type: .default, remote ? 1 : 0, card.last4)
        return false
      }
      let confirmed: Bool
      if let panId = card.panId, !panId.isEmpty {
        confirmed = panIds.contains(panId)
      } else {
        confirmed = last4Counts[card.last4] == 1 && suffixes.contains(card.last4)
      }
      if confirmed {
        // The live library sees the pass — it is the authority from here on.
        EligibilityCache.clearProvisionedMarker(cardId: card.cardId)
        return true
      }
      if now.timeIntervalSince(markedAt) < Self.markerGraceSeconds {
        os_log("eligibility(remote=%{public}d): card last4=%{public}@ excluded (marker, pass materializing)", log: Self.log, type: .default, remote ? 1 : 0, card.last4)
        return false
      }
      EligibilityCache.clearProvisionedMarker(cardId: card.cardId)
      os_log("eligibility(remote=%{public}d): card last4=%{public}@ marker dropped (live library refuted it)", log: Self.log, type: .default, remote ? 1 : 0, card.last4)
      return true
    }

    let keys = cards.map { card in
      ProvisioningEligibility.CardKey(
        panId: card.panId,
        last4: card.last4,
        // Host-app verdict — consulted only when the library is not
        // authoritative. The remote surface mirrors the union rule above:
        // a card already on the iPhone is not offered for the Watch.
        alreadyProvisioned: remote
          ? ((card.onWatch ?? false) || (card.onIphone ?? false))
          : (card.onIphone ?? false)
      )
    }
    let indices = ProvisioningEligibility.eligibleIndices(
      cards: keys,
      provisionedPanIds: panIds,
      provisionedSuffixes: suffixes,
      libraryAuthoritative: authoritative
    )

    // Debug detail: what the live library exposed and how each cached card was
    // judged. panIds are truncated to their last 6 chars — enough to correlate
    // with the app-side sync logs without dumping full FPANIDs.
    let panIdsDesc = panIds.map { String($0.suffix(6)) }.sorted().joined(separator: ",")
    let suffixesDesc = suffixes.sorted().joined(separator: ",")
    // mode=live → passes enumerated; mode=live-empty → empty read but the
    // surface is trusted (live-seen stamp), so empty means empty wallet;
    // mode=flags → library blind, host-app onIphone/onWatch verdicts decide.
    let mode = passes.isEmpty ? (authoritative ? "live-empty" : "flags") : "live"
    os_log(
      "eligibility(remote=%{public}d): mode=%{public}@ %{public}d passes in library — suffixes=[%{public}@] panIds…=[%{public}@] markers=%{public}d",
      log: Self.log, type: .default, remote ? 1 : 0, mode, passes.count, suffixesDesc, panIdsDesc, markers.count
    )
    let eligibleSet = Set(indices)
    for (index, key) in keys.enumerated() {
      os_log(
        "eligibility(remote=%{public}d): card[%{public}d] last4=%{public}@ panId…=%{public}@ → %{public}@",
        log: Self.log, type: .default, remote ? 1 : 0, index, key.last4,
        key.panId.map { String($0.suffix(6)) } ?? "nil",
        eligibleSet.contains(index) ? "ELIGIBLE" : "excluded"
      )
    }
    return indices.map { cards[$0] }
  }

  private func buildEntries(remote: Bool) -> [PKIssuerProvisioningExtensionPaymentPassEntry] {
    guard let file = EligibilityCache.read() else {
      os_log("entries(remote=%{public}d) → [] (no cache)", log: Self.log, type: .default, remote ? 1 : 0)
      return []
    }
    guard EligibilityCache.isFresh(file) else {
      os_log("entries(remote=%{public}d) → [] (stale cache)", log: Self.log, type: .default, remote ? 1 : 0)
      return []
    }
    guard SharedKeychain.isTokenValid() else {
      os_log("entries(remote=%{public}d) → [] (invalid token)", log: Self.log, type: .default, remote ? 1 : 0)
      return []
    }

    let library = PKPassLibrary()

    return eligibleCards(file.cards, in: library, remote: remote).compactMap { card -> PKIssuerProvisioningExtensionPaymentPassEntry? in
      guard let configuration = PKAddPaymentPassRequestConfiguration(encryptionScheme: .ECC_V2) else {
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
