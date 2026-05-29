require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

$RNWallet = Object.new

def $RNWallet._add_compiler_flags(sp, extra_flags)
  exisiting_flags = sp.attributes_hash["compiler_flags"]
  if exisiting_flags.present?
    sp.compiler_flags = exisiting_flags + " #{extra_flags}"
  else
    sp.compiler_flags = extra_flags
  end
end

Pod::Spec.new do |s|
  s.name         = "react-native-wallet"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/Expensify/react-native-wallet.git", :tag => "#{s.version}" }

  s.default_subspecs = "Core"

  # Core — the React Native module consumed by the host app. Links React-Core.
  # Compiles everything under ios/ EXCEPT ios/extension/** (which must not be
  # linked into the app — only into the app-extension target via the
  # WalletExtension subspec below).
  s.subspec "Core" do |ss|
    ss.source_files  = "ios/**/*.{h,m,mm,cpp,swift}"
    ss.exclude_files = "ios/extension/**/*"

    ss.dependency "React-Core"

    install_modules_dependencies(ss)

    if ENV['USE_FRAMEWORKS']
      $RNWallet._add_compiler_flags(ss, "-DRNWallet_USE_FRAMEWORKS=1")
    end
  end

  # WalletExtension — pure-Swift code for the PKIssuerProvisioningExtension
  # app-extension target declared in the host app. Extensions cannot link
  # React Native's binary surface (RN runtime + extension-prohibited APIs fail
  # App Store review), so this subspec depends ONLY on PassKit + Foundation.
  # PKIssuerProvisioningExtensionHandler requires iOS 14.0+.
  #
  # Distinct `module_name` is required: without it, the WalletExtension
  # subspec inherits the pod's default module name (`react_native_wallet`)
  # and CocoaPods generates two modulemaps with the same module name in the
  # same Pods/react-native-wallet directory. The extension target then sees
  # both (Core's via the host target's inherited search paths, plus its own)
  # and fails to compile with "Redefinition of module 'react_native_wallet'".
  # The generated extension subclass in the consumer app must therefore
  # `import react_native_wallet_extension` (the plugin emits this).
  s.subspec "WalletExtension" do |ss|
    ss.module_name   = "react_native_wallet_extension"
    ss.platforms     = { :ios => "14.0" }
    ss.source_files  = "ios/shared/**/*.swift", "ios/extension/**/*.swift"
    ss.frameworks    = "PassKit", "Foundation", "CoreGraphics", "ImageIO", "Security"
  end
end
