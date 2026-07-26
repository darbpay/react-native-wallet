import Foundation
import CoreGraphics
import ImageIO

/// A single eligible card as cached by the host app for the extension to read.
///
/// IMPORTANT — the two-identifier rule:
///  - `cardId` is DarbPay's internal card id. It is used as the
///    `PKIssuerProvisioningExtensionPaymentPassEntry` identifier AND as the
///    `{cardId}` path segment of the encrypt endpoint.
///  - `panId` is Apple's `primaryAccountIdentifier` (captured via the Emcrey
///    `token.added` webhook). It is used ONLY to dedupe against passes already
///    provisioned on the device / paired Watch. It is nil until the card has
///    been provisioned at least once.
struct EligibilityCard: Codable {
  let cardId: String
  let panId: String?
  let last4: String
  let displayName: String
  let cardholderName: String
  let network: String
  let eligibleAt: String
  /// Host-app-computed provisioning state (from `listTokens()` at sync time).
  /// The extension's own PKPassLibrary reads return empty until Apple enables
  /// the payment-pass-provisioning capability for the extension App ID
  /// (verified on-device: 0 passes even with a DarbPay card in the wallet),
  /// so the app — which CAN read the library — ships the answer in the cache.
  /// Optional so caches written by older app versions still decode.
  let onIphone: Bool?
  let onWatch: Bool?
}

/// On-disk shape of `wallet-eligible.json`.
struct EligibilityCacheFile: Codable {
  let cards: [EligibilityCard]
  let writtenAt: String
}

/// Reads/writes the eligibility cache and card-art thumbnails in the App Group
/// container. The host app writes; the extension reads. All accessors degrade
/// gracefully (nil / no-op) when the App Group is unconfigured.
enum EligibilityCache {
  /// The extension treats the cache as usable for this many days after
  /// `writtenAt`. Past this, it returns no entries and asks Wallet to fall
  /// back to "Open DarbPay to add this card."
  static let staleAfterDays = 30

  private static let fileName = "wallet-eligible.json"
  private static let markersFileName = "wallet-provisioned.json"
  private static let liveSeenFileName = "wallet-live-seen.json"
  private static let cardArtDirName = "card-art"

  /// A just-provisioned marker is trusted for this long. Backstop only — the
  /// next app-side cache rewrite clears markers anyway (the app's flags are
  /// fresher and authoritative at that point), and in live mode the handler
  /// clears a marker as soon as the pass library confirms or refutes it.
  static let markerStaleAfterDays = 7

  /// After the extension has seen a non-empty pass library on a surface, an
  /// EMPTY read on that surface is trusted as "genuinely empty wallet" (live
  /// mode) rather than "no library access" (flags fallback) for this long.
  /// Bounded so a revoked/regressed entitlement can't leave the extension
  /// serving ghost lists forever.
  static let liveSeenTrustDays = 90

  // MARK: - Eligibility file

  private static var fileURL: URL? {
    guard let container = SharedAppGroup.containerURL else { return nil }
    let dir = container.appendingPathComponent("Library/Application Support", isDirectory: true)
    return dir.appendingPathComponent(fileName, isDirectory: false)
  }

  /// Writes the given cards with a fresh `writtenAt` timestamp. The native
  /// layer owns `writtenAt` so there is one source of truth for staleness.
  /// Also clears the just-provisioned markers: an app-side sync recomputes
  /// `onIphone`/`onWatch` from its own (working) pass-library read, which
  /// supersedes anything the extension recorded in the meantime.
  static func write(_ cards: [EligibilityCard]) throws {
    guard let fileURL else { return }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let file = EligibilityCacheFile(cards: cards, writtenAt: ISO8601DateFormatter().string(from: Date()))
    let data = try JSONEncoder().encode(file)
    try data.write(to: fileURL, options: .atomic)
    clearProvisionedMarkers()
  }

  /// Reads the cache, or nil if missing / corrupt.
  static func read() -> EligibilityCacheFile? {
    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode(EligibilityCacheFile.self, from: data)
  }

  /// Removes the eligibility file. Called on sign-out.
  static func clear() {
    guard let fileURL else { return }
    try? FileManager.default.removeItem(at: fileURL)
    clearProvisionedMarkers()
  }

  // MARK: - Just-provisioned markers
  //
  // Written by the EXTENSION when it completes the encrypt step for a card,
  // because its own pass-library read returns empty (no App-ID visibility) so
  // it cannot see the pass it just added. Marked cards are excluded from
  // `status()` / `passEntries()` until the app's next sync rewrites the cache
  // with fresh flags (which clears the markers), or the TTL lapses.

  private static var markersURL: URL? {
    guard let container = SharedAppGroup.containerURL else { return nil }
    let dir = container.appendingPathComponent("Library/Application Support", isDirectory: true)
    return dir.appendingPathComponent(markersFileName, isDirectory: false)
  }

  /// Records that the extension just generated an add request for `cardId`.
  static func markProvisioned(cardId: String) {
    guard let markersURL else { return }
    var markers = readMarkers()
    markers[cardId] = ISO8601DateFormatter().string(from: Date())
    guard let data = try? JSONEncoder().encode(markers) else { return }
    try? FileManager.default.createDirectory(
      at: markersURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: markersURL, options: .atomic)
  }

  /// The cardIds with a non-expired just-provisioned marker.
  static func provisionedCardIds(now: Date = Date()) -> Set<String> {
    return Set(provisionedMarkers(now: now).keys)
  }

  /// The non-expired just-provisioned markers with their write timestamps —
  /// the handler needs the age to decide whether an unconfirmed marker is
  /// still inside the "pass is materializing" grace window.
  static func provisionedMarkers(now: Date = Date()) -> [String: Date] {
    let formatter = ISO8601DateFormatter()
    var result: [String: Date] = [:]
    for (cardId, stamp) in readMarkers() {
      guard let written = formatter.date(from: stamp),
            let cutoff = Calendar.current.date(byAdding: .day, value: markerStaleAfterDays, to: written),
            now < cutoff else {
        continue
      }
      result[cardId] = written
    }
    return result
  }

  /// Removes a single marker — called when the live pass library has
  /// confirmed (pass present) or refuted (pass absent past the grace window)
  /// what the marker was bridging.
  static func clearProvisionedMarker(cardId: String) {
    guard let markersURL else { return }
    var markers = readMarkers()
    guard markers.removeValue(forKey: cardId) != nil else { return }
    if markers.isEmpty {
      try? FileManager.default.removeItem(at: markersURL)
    } else if let data = try? JSONEncoder().encode(markers) {
      try? data.write(to: markersURL, options: .atomic)
    }
  }

  static func clearProvisionedMarkers() {
    guard let markersURL else { return }
    try? FileManager.default.removeItem(at: markersURL)
  }

  private static func readMarkers() -> [String: String] {
    guard let markersURL, let data = try? Data(contentsOf: markersURL) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  // MARK: - Live-library sighting stamps
  //
  // The extension cannot ask PassKit "do I have payment-pass visibility?" —
  // an empty enumeration is ambiguous between "no access" and "empty wallet".
  // But visibility is a per-install property: once a surface has returned a
  // real pass, an empty read on that surface later means the wallet is
  // genuinely empty (e.g. the user removed their only card) and must NOT
  // fall back to stale flags. Stamps are per surface (iPhone vs Watch).

  private static var liveSeenURL: URL? {
    guard let container = SharedAppGroup.containerURL else { return nil }
    let dir = container.appendingPathComponent("Library/Application Support", isDirectory: true)
    return dir.appendingPathComponent(liveSeenFileName, isDirectory: false)
  }

  private static func liveSeenKey(remote: Bool) -> String { remote ? "remote" : "local" }

  /// Records that this surface's enumeration returned at least one secure
  /// element pass. Throttled to at most one write per hour per surface.
  static func recordLiveLibrarySeen(remote: Bool, now: Date = Date()) {
    guard let liveSeenURL else { return }
    let formatter = ISO8601DateFormatter()
    var stamps = readLiveSeen()
    if let existing = stamps[liveSeenKey(remote: remote)],
       let existingDate = formatter.date(from: existing),
       now.timeIntervalSince(existingDate) < 3600 {
      return
    }
    stamps[liveSeenKey(remote: remote)] = formatter.string(from: now)
    guard let data = try? JSONEncoder().encode(stamps) else { return }
    try? FileManager.default.createDirectory(
      at: liveSeenURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: liveSeenURL, options: .atomic)
  }

  /// True when this surface returned real passes recently enough that an
  /// empty enumeration should be believed over the app-written flags.
  static func isLiveLibraryTrusted(remote: Bool, now: Date = Date()) -> Bool {
    let formatter = ISO8601DateFormatter()
    guard let stamp = readLiveSeen()[liveSeenKey(remote: remote)],
          let seen = formatter.date(from: stamp),
          let cutoff = Calendar.current.date(byAdding: .day, value: liveSeenTrustDays, to: seen) else {
      return false
    }
    return now < cutoff
  }

  private static func readLiveSeen() -> [String: String] {
    guard let liveSeenURL, let data = try? Data(contentsOf: liveSeenURL) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  /// True when `writtenAt` is within the staleness budget.
  static func isFresh(_ file: EligibilityCacheFile, now: Date = Date()) -> Bool {
    guard let written = ISO8601DateFormatter().date(from: file.writtenAt) else { return false }
    guard let cutoff = Calendar.current.date(byAdding: .day, value: staleAfterDays, to: written) else {
      return false
    }
    return now < cutoff
  }

  // MARK: - Card art

  private static var cardArtDir: URL? {
    guard let container = SharedAppGroup.containerURL else { return nil }
    return container.appendingPathComponent("Library/Caches/\(cardArtDirName)", isDirectory: true)
  }

  private static func cardArtURL(cardId: String, scale: Int) -> URL? {
    cardArtDir?.appendingPathComponent("\(cardId)@\(scale)x.png", isDirectory: false)
  }

  /// Persists a PNG thumbnail for the given card at the given scale (1, 2, 3).
  static func writeCardArt(cardId: String, scale: Int, pngData: Data) throws {
    guard let dir = cardArtDir, let url = cardArtURL(cardId: cardId, scale: scale) else { return }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try pngData.write(to: url, options: .atomic)
  }

  /// Loads the best available card-art thumbnail (3x → 2x → 1x) as a CGImage,
  /// or nil if none is cached.
  static func cardArtImage(cardId: String) -> CGImage? {
    for scale in [3, 2, 1] {
      guard let url = cardArtURL(cardId: cardId, scale: scale),
            let data = try? Data(contentsOf: url),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        continue
      }
      return image
    }
    return nil
  }
}
