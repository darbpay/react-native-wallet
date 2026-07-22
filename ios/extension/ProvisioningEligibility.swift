import Foundation

/// Pure decision core for "which cached cards should the provisioning
/// extension still offer?".
///
/// Dedup keys, in order of authority:
///  1. `panId` (Apple `primaryAccountIdentifier`) — exact, per-pass identity.
///  2. `last4` vs a provisioned pass's `primaryAccountNumberSuffix` — fallback
///     for cards whose `panId` hasn't reached the cache yet (the webhook →
///     backend → app-refetch → cache-rewrite round trip is slow, and the cache
///     may be days stale). Only trusted when the last4 is unique among the
///     cached cards, so a collision can hide a ghost but never an addable card.
///
/// Known limitation, accepted: the suffix set comes from the user's whole pass
/// library, so a same-last4 pass from another issuer can suppress a DarbPay
/// card in the extension list until its real `panId` lands. The in-app add
/// flow is unaffected.
enum ProvisioningEligibility {

  /// The minimal identity of a cached card the decision needs.
  struct CardKey {
    let panId: String?
    let last4: String
    /// Host-app verdict for THIS surface (iPhone or Watch), computed from the
    /// app's own pass-library read at sync time. Authoritative while the
    /// extension's live library reads come back empty (App-ID capability not
    /// backend-enabled); the live panId/suffix checks below still apply on
    /// top so the extension self-corrects the moment they start working.
    let alreadyProvisioned: Bool

    init(panId: String?, last4: String, alreadyProvisioned: Bool = false) {
      // Treat empty-string panId (possible via JSON round trips) as absent.
      self.panId = (panId?.isEmpty ?? true) ? nil : panId
      self.last4 = last4
      self.alreadyProvisioned = alreadyProvisioned
    }
  }

  /// PassKit sometimes returns `primaryAccountNumberSuffix` with a leading
  /// "x"/"X" (e.g. "x1234"). Same rule as `WalletManager.normalizedSuffix`,
  /// duplicated here because WalletManager is not part of the extension target.
  static func normalizedSuffix(_ raw: String?) -> String {
    guard let raw else { return "" }
    if raw.first == "x" || raw.first == "X" { return String(raw.dropFirst()) }
    return raw
  }

  /// Indices (into `cards`) of the cards still eligible for provisioning on
  /// the surface described by `provisionedPanIds` / `provisionedSuffixes`
  /// (iPhone-local passes or paired-Watch remote passes).
  static func eligibleIndices(
    cards: [CardKey],
    provisionedPanIds: Set<String>,
    provisionedSuffixes: Set<String>
  ) -> [Int] {
    var last4Counts: [String: Int] = [:]
    for card in cards {
      last4Counts[card.last4, default: 0] += 1
    }

    // Live mode: the surface's pass list is non-empty, so the library is
    // readable and current — decide from it exclusively. A stale app-written
    // flag must not override it (e.g. pass removed while the app was killed).
    let libraryReadable = !provisionedPanIds.isEmpty || !provisionedSuffixes.isEmpty

    return cards.indices.filter { index in
      let card = cards[index]
      if libraryReadable {
        if let panId = card.panId {
          return !provisionedPanIds.contains(panId)
        }
        // No panId: fall back to suffix matching, but only when this last4
        // uniquely identifies one cached card.
        guard last4Counts[card.last4] == 1 else { return true }
        return !provisionedSuffixes.contains(card.last4)
      }
      // Degraded mode: an empty list means either a genuinely empty wallet
      // (flags are false → same answer) or no library access for this App ID
      // (flags carry the host app's verdict). Either way the flag is the best
      // available truth.
      return !card.alreadyProvisioned
    }
  }
}
