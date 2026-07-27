import CoreGraphics
import Foundation
import ImageIO
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
    // if Console.app doesn't show "gen7", the extension target wasn't rebuilt.
    os_log("status() entered (gen7 live-library-authority)", log: Self.log, type: .default)

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
    // Eligibility is decided against the LIVE pass library, the single
    // authority (Apple dev guide §10.2: exclude passes already on the device;
    // FAQ p.90: "update these values based on their presence"). Card in the
    // library → hidden; card absent → offered, including after a failed add.
    // Both surfaces are answered from ONE library snapshot, and this method
    // performs no writes before completing — Apple ignores the extension if
    // status isn't delivered within 100 ms.
    let snapshot = librarySnapshot()
    let markers = EligibilityCache.provisionedMarkers()
    var markerClears = Set<String>()
    let localEligible = eligibleCards(file.cards, snapshot: snapshot, remote: false, markers: markers, markerClears: &markerClears)
    let remoteEligible = eligibleCards(file.cards, snapshot: snapshot, remote: true, markers: markers, markerClears: &markerClears)
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

    // Bookkeeping strictly AFTER the answer is delivered: marker clears only
    // affect FUTURE invocations (this one already decided from the in-memory
    // snapshot), and losing one to appex teardown is self-healing — the next
    // invocation re-derives the same verdict.
    Self.applyMarkerClears(markerClears)
  }

  // MARK: - entries (<100ms, no network)

  open override func passEntries(completion: @escaping ([PKIssuerProvisioningExtensionPassEntry]) -> Void) {
    let (entries, markerClears) = buildEntries(remote: false)
    completion(entries)
    Self.applyMarkerClears(markerClears)
  }

  open override func remotePassEntries(completion: @escaping ([PKIssuerProvisioningExtensionPassEntry]) -> Void) {
    let (entries, markerClears) = buildEntries(remote: true)
    completion(entries)
    Self.applyMarkerClears(markerClears)
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

  /// Grace window after an extension-side encrypt success during which an
  /// unconfirmed just-provisioned marker still hides the card. This is the
  /// ONLY job markers have left: bridging the few seconds between Wallet
  /// committing a successful add and the pass landing in the library (a
  /// touch longer for the Watch mirror). Past this window an absent pass
  /// means the add failed, was cancelled, or the pass was removed — and the
  /// card MUST be offered again (Issuer Functional Requirements 4.7: offer
  /// provisioning for all Eligible Cards). Keep this short: every second
  /// here is a second a failed add stays invisible in Wallet's "+" list.
  /// 60s covers the Apple/PNO provisioning round trip + library commit with
  /// margin; only a pathologically slow Watch mirror would outlive it, and
  /// the app's next sync corrects that case anyway.
  private static let markerGraceSeconds: TimeInterval = 60

  /// One read of both pass-library surfaces, shared by every decision in a
  /// single extension invocation so iPhone and Watch answers come from the
  /// same snapshot (and the XPC enumeration cost is paid once).
  private struct LibrarySnapshot {
    let localPasses: [PKSecureElementPass]
    let remotePasses: [PKSecureElementPass]
  }

  private func librarySnapshot() -> LibrarySnapshot {
    // passes() + secureElementPass — the exact call the host app's
    // WalletManager uses and is proven to return payment passes. The
    // deprecated passes(of: .payment) filter returned [] in the appex
    // context even with entitlements in place.
    let library = PKPassLibrary()
    return LibrarySnapshot(
      localPasses: library.passes().compactMap { $0.secureElementPass },
      remotePasses: library.remoteSecureElementPasses
    )
  }

  /// Applies deferred marker clears off the caller's thread. Called strictly
  /// AFTER a completion handler has been invoked — clears only influence
  /// future invocations, so the current answer never waits on disk I/O.
  private static func applyMarkerClears(_ cardIds: Set<String>) {
    guard !cardIds.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
      for cardId in cardIds {
        EligibilityCache.clearProvisionedMarker(cardId: cardId)
      }
    }
  }

  /// The cached cards still eligible for the given surface. The LIVE pass
  /// library is the single authority (Apple dev guide §10.2 / FAQ p.90):
  /// present → hidden, absent → offered. Dedup is `panId` first (exact),
  /// then a collision-guarded `last4`-suffix fallback for cards whose
  /// `panId` hasn't reached the cache yet — the decision itself lives in
  /// `ProvisioningEligibility` so it stays unit-testable without PassKit.
  ///
  /// Markers never hide a card beyond `markerGraceSeconds`; cardIds whose
  /// marker is confirmed or refuted by the library are added to
  /// `markerClears` for the caller to apply AFTER its completion handler.
  private func eligibleCards(
    _ cards: [EligibilityCard],
    snapshot: LibrarySnapshot,
    remote: Bool,
    markers: [String: Date],
    markerClears: inout Set<String>,
    now: Date = Date()
  ) -> [EligibilityCard] {
    // Each surface dedupes against its OWN device only (Apple FAQ p.90:
    // "retrieve passes in iPhone and Apple Watch, and update these values
    // based on their presence"): the iPhone list hides iPhone-resident
    // passes, the Watch list hides Watch-resident passes. A card already on
    // the iPhone therefore stays offered on the Watch surface until it is
    // added to the Watch too — only then does it disappear from both lists.
    let passes = remote ? snapshot.remotePasses : snapshot.localPasses
    let panIds = Set(passes.compactMap { $0.primaryAccountIdentifier })
    let suffixes = Set(passes.map { ProvisioningEligibility.normalizedSuffix($0.primaryAccountNumberSuffix) })

    // Just-provisioned markers (extension-side adds whose pass may not have
    // landed yet). Confirmed by a live pass → clear it, the live dedup below
    // hides the card from here on. Unconfirmed within the grace window →
    // hide briefly (the pass may still be materializing after a successful
    // add). Unconfirmed past the grace window → the add failed or the pass
    // was removed again: clear the marker and re-offer the card.
    var last4Counts: [String: Int] = [:]
    for card in cards { last4Counts[card.last4, default: 0] += 1 }
    let cards = cards.filter { card in
      guard let markedAt = markers[card.cardId] else { return true }
      let confirmed: Bool
      if let panId = card.panId, !panId.isEmpty {
        confirmed = panIds.contains(panId)
      } else {
        confirmed = last4Counts[card.last4] == 1 && suffixes.contains(card.last4)
      }
      if confirmed {
        markerClears.insert(card.cardId)
        return true
      }
      if now.timeIntervalSince(markedAt) < Self.markerGraceSeconds {
        os_log("eligibility(remote=%{public}d): card last4=%{public}@ excluded (marker, pass materializing)", log: Self.log, type: .default, remote ? 1 : 0, card.last4)
        return false
      }
      markerClears.insert(card.cardId)
      os_log("eligibility(remote=%{public}d): card last4=%{public}@ marker dropped (no pass in library past grace — re-offering)", log: Self.log, type: .default, remote ? 1 : 0, card.last4)
      return true
    }

    let keys = cards.map { ProvisioningEligibility.CardKey(panId: $0.panId, last4: $0.last4) }
    let indices = ProvisioningEligibility.eligibleIndices(
      cards: keys,
      provisionedPanIds: panIds,
      provisionedSuffixes: suffixes
    )

    // Debug detail: what the live library exposed and how each cached card was
    // judged. panIds are truncated to their last 6 chars — enough to correlate
    // with the app-side sync logs without dumping full FPANIDs.
    let panIdsDesc = panIds.map { String($0.suffix(6)) }.sorted().joined(separator: ",")
    let suffixesDesc = suffixes.sorted().joined(separator: ",")
    os_log(
      "eligibility(remote=%{public}d): %{public}d passes in library — suffixes=[%{public}@] panIds…=[%{public}@] markers=%{public}d",
      log: Self.log, type: .default, remote ? 1 : 0, passes.count, suffixesDesc, panIdsDesc, markers.count
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

  private func buildEntries(remote: Bool) -> (entries: [PKIssuerProvisioningExtensionPaymentPassEntry], markerClears: Set<String>) {
    guard let file = EligibilityCache.read() else {
      os_log("entries(remote=%{public}d) → [] (no cache)", log: Self.log, type: .default, remote ? 1 : 0)
      return ([], [])
    }
    guard EligibilityCache.isFresh(file) else {
      os_log("entries(remote=%{public}d) → [] (stale cache)", log: Self.log, type: .default, remote ? 1 : 0)
      return ([], [])
    }
    guard SharedKeychain.isTokenValid() else {
      os_log("entries(remote=%{public}d) → [] (invalid token)", log: Self.log, type: .default, remote ? 1 : 0)
      return ([], [])
    }

    let snapshot = librarySnapshot()
    let markers = EligibilityCache.provisionedMarkers()
    var markerClears = Set<String>()

    let entries = eligibleCards(file.cards, snapshot: snapshot, remote: remote, markers: markers, markerClears: &markerClears).compactMap { card -> PKIssuerProvisioningExtensionPaymentPassEntry? in
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

      let art = EligibilityCache.cardArtImage(cardId: card.cardId) ?? Self.bundledFallbackArt ?? Self.placeholderArt()
      return PKIssuerProvisioningExtensionPaymentPassEntry(
        identifier: card.cardId,
        title: card.displayName,
        art: art,
        addRequestConfiguration: configuration
      )
    }
    return (entries, markerClears)
  }

  /// Real Darb card art bundled with the pod (1536×969, squared corners per
  /// Issuer Functional Requirements §4.7/§7.2). Used whenever the host app
  /// has not cached a per-card thumbnail via `setWalletExtensionCardArt`,
  /// so Wallet's provisioning sheet never shows a blank tile.
  ///
  /// The PNG ships in the CocoaPods resource bundle
  /// `react-native-wallet-extension.bundle`; probe the class's own bundle
  /// first (framework build), then the appex main bundle (static-lib build).
  private static let bundledFallbackArt: CGImage? = {
    let containers = [Bundle(for: WalletIssuerProvisioningExtensionHandler.self), Bundle.main]
    for container in containers {
      guard let bundleURL = container.url(forResource: "react-native-wallet-extension", withExtension: "bundle"),
            let bundle = Bundle(url: bundleURL),
            let artURL = bundle.url(forResource: "darb-card-art", withExtension: "png"),
            let source = CGImageSourceCreateWithURL(artURL as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        continue
      }
      return image
    }
    os_log("bundled fallback card art missing from resource bundle", log: log, type: .error)
    return nil
  }()

  /// A 1×1 transparent image used only when no card-art thumbnail is cached
  /// AND the bundled fallback art could not be loaded (should never happen).
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
