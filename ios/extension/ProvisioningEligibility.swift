import Foundation

/// Pure decision core for "which cached cards should the provisioning
/// extension still offer?".
///
/// The LIVE pass library is the single authority, exactly as Apple's
/// in-app provisioning guide prescribes (§10.2: "exclude any passes the user
/// has already added to their device"; FAQ p.90: "Use the iOS APIs to
/// retrieve passes in iPhone and Apple Watch, and update these values based
/// on their presence"):
///  - card present in the library  → hidden (already provisioned),
///  - card absent from the library → offered (eligible), including cards
///    whose previous add attempt failed — a failed add leaves no pass, so
///    the card must stay addable (Issuer Functional Requirements 4.7:
///    "Offer Wallet Extension provisioning functionality to all Eligible
///    Cards").
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

    init(panId: String?, last4: String) {
      // Treat empty-string panId (possible via JSON round trips) as absent.
      self.panId = (panId?.isEmpty ?? true) ? nil : panId
      self.last4 = last4
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
  /// (iPhone-local passes, or the iPhone+Watch union for the remote surface).
  static func eligibleIndices(
    cards: [CardKey],
    provisionedPanIds: Set<String>,
    provisionedSuffixes: Set<String>
  ) -> [Int] {
    var last4Counts: [String: Int] = [:]
    for card in cards {
      last4Counts[card.last4, default: 0] += 1
    }

    return cards.indices.filter { index in
      let card = cards[index]
      if let panId = card.panId {
        return !provisionedPanIds.contains(panId)
      }
      // No panId: fall back to suffix matching, but only when this last4
      // uniquely identifies one cached card.
      guard last4Counts[card.last4] == 1 else { return true }
      return !provisionedSuffixes.contains(card.last4)
    }
  }
}
