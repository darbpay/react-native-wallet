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

# Host-app React Native module — links React-Core and exposes the TurboModule
# surface. Compiles everything under ios/ EXCEPT ios/extension/**, which is
# extension-only and lives in the sibling `react-native-wallet-extension`
# podspec (see file in the same directory). The two pods deliberately share
# the ios/shared/** sources so the host-app TurboModule setters and the
# extension handler agree on the App-Group JSON schema, keychain accessor,
# encrypt-endpoint client, etc.
Pod::Spec.new do |s|
  s.name         = "react-native-wallet"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/Expensify/react-native-wallet.git", :tag => "#{s.version}" }

  s.source_files  = "ios/**/*.{h,m,mm,cpp,swift}"
  s.exclude_files = "ios/extension/**/*"

  s.dependency "React-Core"

  install_modules_dependencies(s)

  if ENV['USE_FRAMEWORKS']
    $RNWallet._add_compiler_flags(s, "-DRNWallet_USE_FRAMEWORKS=1")
  end
end
