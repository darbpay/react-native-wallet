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
  /// (backend activation, see FB/DTS forums thread 815110), so the app —
  /// which CAN read the library — ships the answer in the cache. Optional so
  /// caches written by older app versions still decode.
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
  private static let cardArtDirName = "card-art"

  // MARK: - Eligibility file

  private static var fileURL: URL? {
    guard let container = SharedAppGroup.containerURL else { return nil }
    let dir = container.appendingPathComponent("Library/Application Support", isDirectory: true)
    return dir.appendingPathComponent(fileName, isDirectory: false)
  }

  /// Writes the given cards with a fresh `writtenAt` timestamp. The native
  /// layer owns `writtenAt` so there is one source of truth for staleness.
  static func write(_ cards: [EligibilityCard]) throws {
    guard let fileURL else { return }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let file = EligibilityCacheFile(cards: cards, writtenAt: ISO8601DateFormatter().string(from: Date()))
    let data = try JSONEncoder().encode(file)
    try data.write(to: fileURL, options: .atomic)
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
