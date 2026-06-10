import PassKit

struct CardInfo {
  let network: PKPaymentNetwork
  let cardHolderName: String
  let lastDigits: String
  let cardDescription: String
  // Apple FPANID. Optional — only present after a card's first provisioning.
  // When set, it scopes Apple Wallet's provisioning UI to the remaining
  // devices (e.g. "Add to Apple Watch"); see Apple §7.6.
  let primaryAccountIdentifier: String?

  init(cardData: NSDictionary) throws {
    guard let networkString = cardData["network"] as? String, !networkString.isEmpty,
          let network = PaymentNetworkMapper.paymentNetwork(from: networkString),
          let cardHolderName = cardData["cardHolderName"] as? String, !cardHolderName.isEmpty,
          let lastDigits = cardData["lastDigits"] as? String, !lastDigits.isEmpty,
          let cardDescription = cardData["cardDescription"] as? String, !cardDescription.isEmpty else {
      throw CardInfoError.invalidData(description: "Required data fields are missing or invalid.")
    }

    self.network = network
    self.cardHolderName = cardHolderName
    self.lastDigits = lastDigits
    self.cardDescription = cardDescription
    // Optional: the bridge sends "" when absent — normalize that to nil.
    let identifier = cardData["primaryAccountIdentifier"] as? String
    self.primaryAccountIdentifier = (identifier?.isEmpty ?? true) ? nil : identifier
  }
}

enum CardInfoError: Error {
  case invalidData(description: String)
}
