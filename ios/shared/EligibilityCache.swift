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
  /// LEGACY — host-app-computed provisioning state from before the extension
  /// had pass-library visibility. The live PKPassLibrary is now the single
  /// authority (extension visibility verified on-device; requires the
  /// extension bundle id in the pass's `associatedApplicationIdentifiers`),
  /// so these are no longer consulted. Kept optional so cache files written
  /// by current and older app versions still decode.
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
  /// Legacy file from the retired live-seen-stamp mechanism; removed
  /// opportunistically on the next cache write so old installs self-clean.
  private static let legacyLiveSeenFileName = "wallet-live-seen.json"
  private static let cardArtDirName = "card-art"

  /// A just-provisioned marker is trusted for this long. Backstop only — the
  /// handler clears a marker as soon as the live pass library confirms it
  /// (pass present) or the short post-add grace window lapses (pass absent →
  /// card re-offered), and the next app-side cache rewrite clears markers too.
  static let markerStaleAfterDays = 7

  // MARK: - Eligibility file

  private static var fileURL: URL? {
    guard let container = SharedAppGroup.containerURL else { return nil }
    let dir = container.appendingPathComponent("Library/Application Support", isDirectory: true)
    return dir.appendingPathComponent(fileName, isDirectory: false)
  }

  /// Writes the given cards with a fresh `writtenAt` timestamp. The native
  /// layer owns `writtenAt` so there is one source of truth for staleness.
  /// Also clears the just-provisioned markers: an app-side sync means the
  /// live pass library has already been consulted by the app, which
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
    removeLegacyLiveSeenFile()
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

  /// Removes the file left behind by the retired live-seen-stamp mechanism
  /// (pre-gen7 handlers used it to decide whether an empty pass-library read
  /// could be trusted; the live library is now always the authority).
  private static func removeLegacyLiveSeenFile() {
    guard let container = SharedAppGroup.containerURL else { return }
    let url = container
      .appendingPathComponent("Library/Application Support", isDirectory: true)
      .appendingPathComponent(legacyLiveSeenFileName, isDirectory: false)
    try? FileManager.default.removeItem(at: url)
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
