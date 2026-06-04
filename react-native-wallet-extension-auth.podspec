require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Pure-Swift pod for the iOS PKIssuerProvisioningExtensionAuthorizationProviding
# app-extension target (P0-2 §4.7 — UI extension half of Apple's two-extension
# wallet-initiated provisioning architecture, DEV-4.0 §10). Lives in the host
# app's UI-extension target ONLY — neither the host-app pod
# (`react-native-wallet`) nor the non-UI extension pod
# (`react-native-wallet-extension`) depends on this one.
#
# Distinct pod name (and therefore distinct CocoaPods module name) is
# required: the UI extension and non-UI extension are sibling app-extension
# binaries that ship together inside the same .ipa, but each has its own
# binary, entitlements, and bundle id. Their Swift sources must compile into
# distinct modules so the two modulemaps don't collide.
#
# Like the non-UI extension pod, this binary cannot link the React Native
# runtime (app-extension API constraints + binary-size budget). Frameworks
# limited to PassKit, Foundation, UIKit (UI extension needs UIViewController
# hosting), and Security (for shared keychain access from Iteration 2 onward).
#
# PKIssuerProvisioningExtensionAuthorizationProviding requires iOS 14.0+.
Pod::Spec.new do |s|
  s.name         = "react-native-wallet-extension-auth"
  s.version      = package["version"]
  s.summary      = "WalletAuthExtension (UI) target for @darbpay/react-native-wallet."
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "14.0" }
  s.source       = { :git => "https://github.com/Expensify/react-native-wallet.git", :tag => "#{s.version}" }

  s.source_files = "ios/shared/**/*.swift", "ios/extension-auth/**/*.swift"
  s.frameworks   = "PassKit", "Foundation", "UIKit", "Security"
end
