import Foundation
import os.log

/// Fetches the signed-in user's provisionable cards from the issuer backend
/// and rebuilds the App Group eligibility cache. Runs inside the UI auth
/// extension right after a successful inline sign-in, so a user who
/// authenticates from Apple Wallet sees THEIR cards — not whatever the
/// previously signed-in account left in the cache (multi-account fix).
///
/// Mirrors the host app's catalog rules (`use-wallet-extension-cache.ts` +
/// `wallet-eligibility.ts`):
///  - `GET {base}/cards/expense` → expense cards, `GET {base}/v1/cards` → the
///    fleet card, both under `WalletExtensionEncryptBaseUrl` with the freshly
///    minted Bearer token.
///  - Keep `status == ACTIVE`, drop `formFactor == KEYCHAIN` (shared
///    vehicle fobs are never offered in a personal Wallet).
///  - `onIphone`/`onWatch` flags are omitted: the non-UI extension filters
///    against the live pass library at every poll, and the app's next sync
///    rewrites the cache with computed flags anyway.
///
/// Best-effort by design: any failure leaves the existing cache untouched
/// (same-user re-login — the common case — keeps working), and the caller
/// still reports `.authorized`.
@available(iOS 14.0, *)
enum WalletCardsClient {

  private static let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "react-native-wallet-extension-auth",
    category: "cards"
  )

  private static let requestTimeout: TimeInterval = 15

  /// Wire shape shared by both endpoints (`components.schemas.CreditCard` in
  /// the employee API spec). Every field optional — tolerate additions.
  private struct CreditCard: Decodable {
    let id: String?
    let cardNumber: String?
    let cardHolderName: String?
    let status: String?
    let type: String?
    let formFactor: String?
    let applePayPrimaryAccountIdentifier: String?
  }

  private struct ExpenseCardsResponse: Decodable { let data: [CreditCard]? }
  private struct FleetCardResponse: Decodable { let data: CreditCard? }

  /// Fetches both card sources and rewrites the eligibility cache. Returns
  /// true when the cache was rewritten. Never throws — logs and returns false
  /// so the sign-in flow proceeds either way.
  static func refreshEligibleCards(bearerToken: String, fallbackName: String) async -> Bool {
    guard let base = Bundle.main.object(forInfoDictionaryKey: WalletProvisioningClient.encryptBaseUrlKey) as? String,
          !base.isEmpty else {
      os_log("cards refresh skipped — no encrypt base URL in Info.plist", log: log, type: .error)
      return false
    }

    // Both fetches must succeed before touching the cache — a partial catalog
    // (e.g. expense cards without the fleet card) would silently hide cards.
    async let expenseData = fetchData(urlString: "\(base)/cards/expense", token: bearerToken)
    async let fleetData = fetchData(urlString: "\(base)/v1/cards", token: bearerToken)
    guard let expenseBytes = await expenseData, let fleetBytes = await fleetData else {
      os_log("cards refresh skipped — fetch failed, keeping existing cache", log: log, type: .error)
      return false
    }

    guard let expense = try? JSONDecoder().decode(ExpenseCardsResponse.self, from: expenseBytes) else {
      os_log("cards refresh skipped — expense decode failed", log: log, type: .error)
      return false
    }
    // The fleet endpoint legitimately returns no card for expense-only users;
    // only a malformed body is an error.
    let fleet = try? JSONDecoder().decode(FleetCardResponse.self, from: fleetBytes)

    var candidates = expense.data ?? []
    if let fleetCard = fleet?.data {
      candidates.append(fleetCard)
    }

    let cards: [EligibilityCard] = candidates.compactMap { card in
      guard let id = card.id, !id.isEmpty,
            let cardNumber = card.cardNumber else { return nil }
      guard card.status == "ACTIVE", card.formFactor != "KEYCHAIN" else { return nil }
      let last4 = String(cardNumber.filter(\.isNumber).suffix(4))
      guard !last4.isEmpty else { return nil }
      let holder = card.cardHolderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return EligibilityCard(
        cardId: id,
        panId: (card.applePayPrimaryAccountIdentifier?.isEmpty ?? true) ? nil : card.applePayPrimaryAccountIdentifier,
        last4: last4,
        displayName: displayName(for: card.type),
        cardholderName: holder.isEmpty ? fallbackName : holder,
        network: "visa",
        eligibleAt: ISO8601DateFormatter().string(from: Date()),
        onIphone: nil,
        onWatch: nil
      )
    }

    do {
      try EligibilityCache.write(cards)
      os_log("cards refresh OK — %{public}d eligible cards cached", log: log, type: .default, cards.count)
      return true
    } catch {
      os_log("cards refresh write failed: %{public}@", log: log, type: .error, error.localizedDescription)
      return false
    }
  }

  /// Port of the app's `getCardDescription` (`lib/card-display.ts`).
  private static func displayName(for type: String?) -> String {
    switch type {
    case "FLEET": return "DarbPay Fleet Card"
    case "EXPENSE": return "DarbPay Expense Card"
    default: return "DarbPay Card"
    }
  }

  /// GET with Bearer auth; nil on any transport or non-2xx failure.
  private static func fetchData(urlString: String, token: String) async -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    return await withCheckedContinuation { continuation in
      URLSession.shared.dataTask(with: request) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, (200...299).contains(status), let data else {
          os_log(
            "GET %{public}@ failed — status=%d error=%{public}@",
            log: log, type: .error, urlString, status, error?.localizedDescription ?? "none"
          )
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: data)
      }.resume()
    }
  }
}
