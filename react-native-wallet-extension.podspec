require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Pure-Swift pod for the iOS PKIssuerProvisioningExtension app-extension
# target (P0-2 §4.7). Lives in the host app's extension target ONLY — the
# host-app pod (`react-native-wallet`) does NOT depend on this one.
#
# Distinct pod name (and therefore distinct CocoaPods module name) is
# required: when this code lived as a subspec under `react-native-wallet`,
# both subspecs claimed the same `react_native_wallet` module and the
# extension target failed to compile with
# "Redefinition of module 'react_native_wallet'". CocoaPods rejects
# `module_name` on subspecs, so the only clean fix is a separate pod.
#
# Extensions cannot link React Native's binary surface (the RN runtime plus
# extension-prohibited APIs like UIApplication.shared fail App Store review),
# so this pod depends on PassKit + Foundation only.
# PKIssuerProvisioningExtensionHandler requires iOS 14.0+.
Pod::Spec.new do |s|
  s.name         = "react-native-wallet-extension"
  s.version      = package["version"]
  s.summary      = "WalletExtension target for @darbpay/react-native-wallet."
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "14.0" }
  s.source       = { :git => "https://github.com/Expensify/react-native-wallet.git", :tag => "#{s.version}" }

  s.source_files = "ios/shared/**/*.swift", "ios/extension/**/*.swift"
  s.frameworks   = "PassKit", "Foundation", "CoreGraphics", "ImageIO", "Security"

  # Bundled fallback card art (Issuer Functional Requirements §4.7 requires
  # real card art in the provisioning flow; a blank placeholder is not
  # compliant). Shipped as a named resource bundle so the extension can load
  # it regardless of whether the pod is built as a static lib or framework.
  s.resource_bundles = {
    "react-native-wallet-extension" => ["ios/extension/Resources/*.png"]
  }
end
