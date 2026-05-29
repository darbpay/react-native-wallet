import Foundation
import PassKit
import UIKit
import React

public typealias CompletionHandler = (OperationResult, NSDictionary?) -> Void

@objc public protocol WalletDelegate {
  func sendEvent(name: String, result: NSDictionary)
}

@objc
open class WalletManager: UIViewController {
  
  @objc public weak var delegate: WalletDelegate? = nil
  
  private var addPassViewController: PKAddPaymentPassViewController?

  private var presentAddPaymentPassCompletionHandler: (CompletionHandler)?
  
  private var addPaymentPassCompletionHandler: (CompletionHandler)?

  private var addPassHandler: ((PKAddPaymentPassRequest) -> Void)?
  
  @objc public var packageName = "react-native-wallet"
  
  let passLibrary = PKPassLibrary()

  override init(nibName: String?, bundle: Bundle?) {
    super.init(nibName: nibName, bundle: bundle)
    addPassObserver()
  }
  
  required public init?(coder: NSCoder) {
    super.init(coder: coder)
    addPassObserver()
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  func addPassObserver() {
    // object: nil so we listen to notifications from any PKPassLibrary instance,
    // not only this one. The OS sometimes posts from a different instance.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(passLibraryDidChange),
      name: NSNotification.Name(rawValue: PKPassLibraryNotificationName.PKPassLibraryDidChange.rawValue),
      object: nil
    )
  }

  @objc func passLibraryDidChange(_ notification: Notification) {
    self.logInfo(message: "passLibraryDidChange fired. userInfo keys: \(notification.userInfo?.keys.map { "\($0)" } ?? [])")

    guard let userInfo = notification.userInfo else {
      return
    }

    // Check if passes were added or status changed
    if let addedPasses = userInfo[PKPassLibraryNotificationKey.addedPassesUserInfoKey] as? [PKPass] {
      checkPassActivationStatus(addedPasses)
    }

    // Check for updated passes
    if let replacedPasses = userInfo[PKPassLibraryNotificationKey.replacementPassesUserInfoKey] as? [PKPass] {
      checkPassActivationStatus(replacedPasses)
    }

    // Check for removed passes. Apple delivers these as an array of metadata
    // dictionaries (the PKPass objects no longer exist), keyed by typed
    // PKPassLibraryNotificationKey constants — not literal "serialNumber".
    if let removedInfos = userInfo[PKPassLibraryNotificationKey.removedPassInfosUserInfoKey] as? [[AnyHashable: Any]] {
      for info in removedInfos {
        guard let serial = info[PKPassLibraryNotificationKey.serialNumberUserInfoKey] as? String else {
          continue
        }
        let passTypeId = info[PKPassLibraryNotificationKey.passTypeIdentifierUserInfoKey] as? String ?? ""
        delegate?.sendEvent(name: Event.onCardRemoved.rawValue, result: [
          "tokenId": serial,
          "passTypeIdentifier": passTypeId
        ])
      }
    }
  }
  
  func checkPassActivationStatus(_ passes: [PKPass]) {
    for pass in passes {
      guard let secure = pass.secureElementPass else {
        self.logInfo(message: "Pass without secureElementPass: serial=\(pass.serialNumber)")
        continue
      }
      let status = mapActivationState(secure.passActivationState)
      self.logInfo(message: "Emitting onCardActivated: status=\(status) serial=\(pass.serialNumber)")
      delegate?.sendEvent(name: Event.onCardActivated.rawValue, result: [
        "status": status,
        "tokenId": pass.serialNumber
      ])
    }
  }

  private func mapActivationState(_ state: PKSecureElementPass.PassActivationState) -> String {
    switch state {
    case .activated: return "activated"
    case .requiresActivation: return "requiresActivation"
    case .activating: return "pending"
    case .suspended: return "suspended"
    case .deactivated: return "deactivated"
    @unknown default: return "unknown"
    }
  }

  @objc
  public func checkWalletAvailability() -> Bool {
    return isPassKitAvailable();
  }
  
  @objc
  public func IOSPresentAddPaymentPassView(cardData: NSDictionary, completion: @escaping CompletionHandler) {
    guard isPassKitAvailable() else {
      completion(.error, [
        "errorMessage": "InApp enrollment not available for this device"
      ])
      return
    }
    
    let card: CardInfo
    do {
      card = try CardInfo(cardData: cardData)
    }
    catch {
      completion(.error, [
        "errorMessage": "Invalid card data. Please check your card information and try again..."
      ])
      return
    }
    
    guard let configuration = PKAddPaymentPassRequestConfiguration(encryptionScheme: .ECC_V2) else {
      completion(.error, [
        "errorMessage": "InApp enrollment configuraton fails"
      ])
      return
    }
    
    configuration.cardholderName = card.cardHolderName
    configuration.primaryAccountSuffix = card.lastDigits
    configuration.localizedDescription = String(card.cardDescription)

    guard let enrollViewController = PKAddPaymentPassViewController(requestConfiguration: configuration, delegate: self) else {
      completion(.error, [
        "errorMessage": "InApp enrollment controller configuration fails"
      ])
      return
    }
    
    presentAddPaymentPassCompletionHandler = completion
    DispatchQueue.main.async {
      if self.addPassViewController == nil {
        self.addPassViewController = enrollViewController
        RCTPresentedViewController()?.present(enrollViewController, animated: true, completion: nil)
      } else {
        self.logInfo(message: "EnrollViewController is already presented.")
      }
    }
  }
  
  @objc
  public func IOSHandleAddPaymentPassResponse(payload: NSDictionary, completion: @escaping CompletionHandler) {
    guard addPassHandler != nil else {
      hideModal()
      completion(.error, [
        "errorMessage": "addPassHandler unavailable"
      ])
      return
    }

    let walletData: WalletEncryptedPayload
    do {
      walletData = try WalletEncryptedPayload(data: payload)
    } catch {
      hideModal()
      completion(.error, [
        "errorMessage": "Invalid payload data"
      ])
      return
    }
    
    self.addPaymentPassCompletionHandler = completion
    
    let addPaymentPassRequest = PKAddPaymentPassRequest()
    addPaymentPassRequest.encryptedPassData = walletData.encryptedPassData
    addPaymentPassRequest.activationData = walletData.activationData
    addPaymentPassRequest.ephemeralPublicKey = walletData.ephemeralPublicKey
    self.addPassHandler?(addPaymentPassRequest)
    self.addPassHandler = nil
  }
  
  private func getPassActivationState(matching condition: (PKSecureElementPass) -> Bool) -> NSNumber {
    let paymentPasses = passLibrary.passes(of: .payment)
    if paymentPasses.isEmpty {
      self.logInfo(message: "No passes found in Wallet.")
      return -1
    }

    for pass in paymentPasses {
      guard let securePassElement = pass.secureElementPass else { continue }
      if condition(securePassElement) {
        return NSNumber(value: securePassElement.passActivationState.rawValue)
      }
    }
    return -1
  }
  
  @objc public func getCardStatusBySuffix(last4Digits: NSString) -> NSNumber {
    return getPassActivationState { pass in
      return pass.primaryAccountNumberSuffix.hasSuffix(last4Digits as String)
    }
  }

  @objc public func getCardStatusByIdentifier(identifier: NSString) -> NSNumber {
    return getPassActivationState { pass in
      return pass.primaryAccountIdentifier == identifier as String
    }
  }

  @objc public func listPasses() -> NSArray {
    let allPasses = passLibrary.passes()
    self.logInfo(message: "DEBUG all passes count: \(allPasses.count)")
    for pass in allPasses {
      self.logInfo(message: "DEBUG pass type=\(pass.passType.rawValue) passTypeIdentifier=\(pass.passTypeIdentifier) serialNumber=\(pass.serialNumber)")
    }

    let paymentPasses = passLibrary.passes(of: .payment)
    self.logInfo(message: "DEBUG payment passes count: \(paymentPasses.count)")
    var results: [NSDictionary] = []
    for pass in paymentPasses {
      guard let secure = pass.secureElementPass else { continue }
      results.append([
        "identifier": secure.primaryAccountIdentifier ?? "",
        "lastDigits": secure.primaryAccountNumberSuffix ?? "",
        "tokenState": secure.passActivationState.rawValue,
      ])
    }

    return results as NSArray
  }
  
  private func isPassKitAvailable() -> Bool {
    return PKAddPaymentPassViewController.canAddPaymentPass()
  }
  
  private func hideModal() {
    DispatchQueue.main.async {
      if let enrollVC = self.addPassViewController, enrollVC.isBeingPresented || enrollVC.presentingViewController != nil {
        enrollVC.dismiss(animated: true, completion: {
          self.addPassViewController = nil
        })
      } else {
        self.logInfo(message: "EnrollViewController is not presented currently.")
      }
    }
  }
  
  private func logInfo(message: String) {
    print("[\(packageName)] \(message)")
  }
}

extension WalletManager: PKAddPaymentPassViewControllerDelegate {
  // Perform the bridge from Apple -> Issuer -> Apple
  public func addPaymentPassViewController(
    _ controller: PKAddPaymentPassViewController,
    generateRequestWithCertificateChain certificates: [Data],
    nonce: Data, nonceSignature: Data,
    completionHandler handler: @escaping (PKAddPaymentPassRequest) -> Void) {
      let stringNonce = nonce.base64EncodedString() as NSString
      let stringNonceSignature = nonceSignature.base64EncodedString() as NSString
      let stringCertificates = certificates.map {
        $0.base64EncodedString() as NSString
      }
      let reqestCardData = AddPassResponse(status: .completed, nonce: stringNonce, nonceSignature: stringNonceSignature, certificates: stringCertificates)
      self.addPassHandler = handler
      
      // Retry the JS issuer callback if the user tries again to add a payment pass
      if let addPaymentPassHandler = addPaymentPassCompletionHandler {
        addPaymentPassHandler(.retry, reqestCardData.toNSDictionary())
        addPaymentPassCompletionHandler = nil
        return
      }
      
      // Finish IOSPresentAddPaymentPassView function
      if let presentPassHandler = presentAddPaymentPassCompletionHandler {
        presentPassHandler(.completed, reqestCardData.toNSDictionary())
        presentAddPaymentPassCompletionHandler = nil
      }
    }
    
  // This method will be called when enroll process ends (with success/error)
  public func addPaymentPassViewController(
    _ controller: PKAddPaymentPassViewController,
    didFinishAdding pass: PKPaymentPass?,
    error: Error?) {
      if addPassViewController == nil {
        return
      }

      let errorInfo = describePassKitError(error)

      if let error = error {
        self.logInfo(message: "PassKit error: domain=\(errorInfo["errorDomain"] ?? "") code=\(errorInfo["errorCode"] ?? "") reason=\(errorInfo["errorReason"] ?? "") description=\(error.localizedDescription)")
        delegate?.sendEvent(name: Event.onCardActivated.rawValue, result:  [
          "status": "canceled"
        ]);
      }

      // Cancel the IOSPresentAddPaymentPassView function when the user cancelled the modal
      if let handler = presentAddPaymentPassCompletionHandler {
        let response = AddPassResponse(status: .canceled, nonce: nil, nonceSignature: nil, certificates: nil)
        handler(.canceled, response.toNSDictionary())
      }

      // If the pass is returned complete the IOSHandleAddPaymentPassResponse function
      if let addPaymentPassHandler = addPaymentPassCompletionHandler {
        if pass != nil {
          addPaymentPassHandler(.completed, nil)
        } else {
          let reason = errorInfo["errorReason"] as? String ?? "unknownError"
          let description = (error?.localizedDescription).map { ": \($0)" } ?? ""
          var payload: [String: Any] = [
            "errorMessage": "Could not add card (\(reason))\(description)"
          ]
          payload.merge(errorInfo) { current, _ in current }
          addPaymentPassHandler(.error, payload as NSDictionary)
        }
      }

      hideModal()
      addPaymentPassCompletionHandler = nil
      presentAddPaymentPassCompletionHandler = nil
    }

  private func describePassKitError(_ error: Error?) -> [String: Any] {
    guard let error = error else { return [:] }
    let nsError = error as NSError

    var info: [String: Any] = [
      "errorDomain": nsError.domain,
      "errorCode": nsError.code,
      "errorDescription": nsError.localizedDescription
    ]

    if nsError.domain == PKPassKitErrorDomain {
      info["errorReason"] = passKitErrorReason(code: nsError.code)
    }

    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      info["underlyingDomain"] = underlying.domain
      info["underlyingCode"] = underlying.code
      info["underlyingDescription"] = underlying.localizedDescription
    }

    if let failureReason = nsError.localizedFailureReason {
      info["failureReason"] = failureReason
    }
    if let recovery = nsError.localizedRecoverySuggestion {
      info["recoverySuggestion"] = recovery
    }

    return info
  }

  private func passKitErrorReason(code: Int) -> String {
    // Maps PKAddPaymentPassError raw values to readable reasons.
    // Apple does not expose every PKPassKitErrorDomain code as an enum,
    // so unknown codes fall through to a generic label.
    switch code {
    case 0: return "unknownError"
    case 1: return "userCancelled"
    case 2: return "invalidSignature"
    case 3: return "notEntitled"
    default: return "passKitError(\(code))"
    }
  }
}

// MARK: - Wallet Extension cache (P0-2 §4.7)
//
// These setters let JS keep the App Group container fresh for the
// PKIssuerProvisioningExtension. They delegate to the shared layer
// (`EligibilityCache` / `SharedKeychain`). When the App Group is unconfigured
// (consumer hasn't enabled the Expo plugin), `SharedAppGroup.identifier` is nil
// and the shared helpers no-op, so these stay backward compatible.
//
// Each returns an error message String (nil on success) so the Obj-C bridge can
// resolve/reject without an NSError out-parameter.
extension WalletManager {
  @objc public func setWalletExtensionEligibleCards(cardsJson: NSString) -> NSString? {
    guard let data = (cardsJson as String).data(using: .utf8) else {
      return "invalid_cards_json_encoding"
    }
    do {
      let cards = try JSONDecoder().decode([EligibilityCard].self, from: data)
      try EligibilityCache.write(cards)
      return nil
    } catch {
      return "eligible_cards_write_failed: \(error.localizedDescription)" as NSString
    }
  }

  @objc public func clearWalletExtensionEligibleCards() {
    EligibilityCache.clear()
  }

  @objc public func setWalletExtensionAuthToken(token: NSString, expiresAtMs: Double) -> NSString? {
    let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000.0)
    do {
      try SharedKeychain.setAuthToken(token as String, expiresAt: expiresAt)
      return nil
    } catch {
      return "auth_token_write_failed: \(error.localizedDescription)" as NSString
    }
  }

  @objc public func clearWalletExtensionAuthToken() {
    SharedKeychain.clearAuthToken()
  }

  @objc public func setWalletExtensionCardArt(cardId: NSString, scale: Int, pngBase64: NSString) -> NSString? {
    guard let pngData = Data(base64Encoded: pngBase64 as String) else {
      return "invalid_card_art_base64"
    }
    do {
      try EligibilityCache.writeCardArt(cardId: cardId as String, scale: scale, pngData: pngData)
      return nil
    } catch {
      return "card_art_write_failed: \(error.localizedDescription)" as NSString
    }
  }
}

extension WalletManager {
  enum Event: String, CaseIterable {
    case onCardActivated
    case onCardRemoved
  }

  @objc
  public static var supportedEvents: [String] {
    return Event.allCases.map(\.rawValue);
  }
}
