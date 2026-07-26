import {execSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, readdirSync, statSync, writeFileSync} from 'node:fs';
import {extname, join, resolve} from 'node:path';
import type {ConfigPlugin, XcodeProject} from '@expo/config-plugins';
import {createRunOncePlugin, withDangerousMod, withEntitlementsPlist, withInfoPlist, withPodfile, withProjectBuildGradle, withXcodeProject} from '@expo/config-plugins';
import {createGeneratedHeaderComment, removeGeneratedContents} from '@expo/config-plugins/build/utils/generateCode';

/**
 * Configuration for the iOS PKIssuerProvisioningExtension app-extension
 * (P0-2 §4.7). When present, the plugin creates the extension target, wires the
 * shared App Group, and generates the extension's Info.plist / entitlements /
 * Swift subclass on `expo prebuild`.
 */
export type WalletExtensionConfig = {
  /** App Group shared between the host app and the extension, e.g. "group.com.darbpay.mobile". */
  appGroup: string;
  /** Base URL of the issuer encrypt endpoint, e.g. "https://api.darbpay.com/api/employee". The extension appends `/cards/{cardId}/apple-pay/encrypt`. */
  encryptBaseUrl: string;
  /** Bundle id suffix appended to the host app's bundle id. Default ".walletextension". */
  bundleSuffix?: string;
  /** Xcode target + folder name. Default "WalletExtension". */
  targetName?: string;
  /** Principal class name (the brand subclass). Default "DarbProvisioningExtension". */
  className?: string;
  /**
   * Sibling UI extension (`PKIssuerProvisioningExtensionAuthorizationProviding`)
   * that lets Wallet present a native login UI when the non-UI extension
   * reports `requiresAuthentication = true`. Apple's two-extension
   * architecture — see DEV-4.0 §10. Omit to ship only the non-UI extension.
   *
   * Iteration 1 of P0-2 §4.7 UI extension: walking skeleton (placeholder VC,
   * no real auth). Iteration 2 fills in the Clerk REST integration.
   */
  auth?: WalletExtensionAuthConfig;
};

/**
 * Configuration for the iOS PKIssuerProvisioningExtensionAuthorizationProviding
 * UI extension (P0-2 §4.7 UI extension). Nested under
 * `WalletExtensionConfig.auth` so the UI extension always inherits the parent
 * extension's App Group — the two extensions communicate exclusively through
 * that shared container at runtime.
 */
export type WalletExtensionAuthConfig = {
  /** Bundle id suffix appended to the host app's bundle id. Default ".walletauthextension". */
  bundleSuffix?: string;
  /** Xcode target + folder name. Default "WalletAuthExtension". */
  targetName?: string;
  /** Principal class name (the brand subclass). Default "DarbWalletAuthExtension". */
  className?: string;
  /**
   * Clerk publishable key (e.g. "pk_test_…" / "pk_live_…"). The UI extension
   * derives the Clerk Frontend API host from it to run the inline phone+OTP
   * sign-in. Publishable keys are public — safe to embed in the Info.plist.
   * Required when the inline auth UI should actually sign the user in.
   */
  clerkPublishableKey?: string;
  /**
   * Clerk JWT template the extension mints after sign-in and writes to the
   * shared keychain. Must match the template the host app uses. Default
   * "wallet_extension".
   */
  jwtTemplate?: string;
};

export type ReactNativeWalletConfig = {
  /**
   * Path to the Google TapAndPay SDK for Android
   * This should be the path to a ZIP file containing the Google TapAndPay SDK files,
   * or a directory containing the SDK files, or a single SDK file (.aar)
   */
  googleTapAndPaySdkPath?: string;
  /**
   * iOS Apple Pay In-App Provisioning entitlement
   * default true
   */
  enableApplePayProvisioning?: boolean;
  /**
   * iOS Wallet-app-initiated provisioning extension (P0-2 §4.7).
   * Omit to leave the extension target out entirely (default).
   */
  walletExtension?: WalletExtensionConfig;
};

const EXTENSION_DEFAULTS = {
  bundleSuffix: '.walletextension',
  targetName: 'WalletExtension',
  className: 'DarbProvisioningExtension',
  appGroupInfoPlistKey: 'WalletExtensionAppGroup',
  encryptBaseUrlInfoPlistKey: 'WalletExtensionEncryptBaseUrl',
  // The canonical Apple identifier for a `PKIssuerProvisioningExtensionHandler`
  // host. Quoted directly from Apple's In-App Provisioning Extensions reference
  // (https://applepaydemo.apple.com/in-app-provisioning-extensions) and the
  // PassKit framework docs. There is NO `-extension` suffix — TestFlight's
  // submission validator rejects the wrong literal with ITMS-90349
  // "NSExtensionPointIdentifier ... is invalid", which despite the wording
  // is a string-match failure against Apple's extension-point registry, not
  // an entitlement issue.
  //
  // The sibling UI-extension identifier is
  // `com.apple.PassKit.issuer-provisioning.authorization` — see
  // `AUTH_EXTENSION_DEFAULTS.extensionPointIdentifier` below.
  extensionPointIdentifier: 'com.apple.PassKit.issuer-provisioning',
} as const;

const AUTH_EXTENSION_DEFAULTS = {
  bundleSuffix: '.walletauthextension',
  targetName: 'WalletAuthExtension',
  className: 'DarbWalletAuthExtension',
  jwtTemplate: 'wallet_extension',
  clerkPublishableKeyInfoPlistKey: 'WalletExtensionClerkPublishableKey',
  jwtTemplateInfoPlistKey: 'WalletExtensionJwtTemplate',
  // Sibling of `EXTENSION_DEFAULTS.extensionPointIdentifier` with the
  // `.authorization` suffix — the canonical Apple identifier for a host of
  // `PKIssuerProvisioningExtensionAuthorizationProviding`. Same ITMS-90349
  // string-match rules apply.
  extensionPointIdentifier: 'com.apple.PassKit.issuer-provisioning.authorization',
} as const;

type ResolvedExtensionConfig = {
  appGroup: string;
  encryptBaseUrl: string;
  bundleSuffix: string;
  targetName: string;
  className: string;
  auth?: ResolvedAuthExtensionConfig;
};

type ResolvedAuthExtensionConfig = {
  /** Inherited from the parent walletExtension config — the two extensions share state via this App Group. */
  appGroup: string;
  /**
   * Inherited from the parent walletExtension config. The auth extension
   * refreshes the eligibility cache with the logged-in user's cards right
   * after a successful inline sign-in (multi-account correctness), so it
   * needs the same issuer API base the non-UI extension uses for encrypt.
   */
  encryptBaseUrl: string;
  bundleSuffix: string;
  targetName: string;
  className: string;
  clerkPublishableKey: string;
  jwtTemplate: string;
};

function resolveExtensionConfig(config: WalletExtensionConfig): ResolvedExtensionConfig {
  const resolved: ResolvedExtensionConfig = {
    appGroup: config.appGroup,
    encryptBaseUrl: config.encryptBaseUrl,
    bundleSuffix: config.bundleSuffix ?? EXTENSION_DEFAULTS.bundleSuffix,
    targetName: config.targetName ?? EXTENSION_DEFAULTS.targetName,
    className: config.className ?? EXTENSION_DEFAULTS.className,
  };
  if (config.auth) {
    resolved.auth = resolveAuthExtensionConfig(resolved.appGroup, resolved.encryptBaseUrl, config.auth);
  }
  return resolved;
}

function resolveAuthExtensionConfig(appGroup: string, encryptBaseUrl: string, auth: WalletExtensionAuthConfig): ResolvedAuthExtensionConfig {
  return {
    appGroup,
    encryptBaseUrl,
    bundleSuffix: auth.bundleSuffix ?? AUTH_EXTENSION_DEFAULTS.bundleSuffix,
    targetName: auth.targetName ?? AUTH_EXTENSION_DEFAULTS.targetName,
    className: auth.className ?? AUTH_EXTENSION_DEFAULTS.className,
    clerkPublishableKey: auth.clerkPublishableKey ?? '',
    jwtTemplate: auth.jwtTemplate ?? AUTH_EXTENSION_DEFAULTS.jwtTemplate,
  };
}

interface AppendContentsParams {
  src: string;
  newSrc: string;
  tag: string;
  comment: string;
}

function appendContents({src, newSrc, tag, comment}: AppendContentsParams): {
  contents: string;
  didClear: boolean;
  didMerge: boolean;
} {
  const header = createGeneratedHeaderComment(newSrc, tag, comment);
  if (!src.includes(header)) {
    const sanitizedTarget = removeGeneratedContents(src, tag);
    const contentsToAdd = [header, newSrc, `${comment} @generated end ${tag}`].join('\n');

    return {
      contents: `${sanitizedTarget ?? src}\n${contentsToAdd}`,
      didClear: !!sanitizedTarget,
      didMerge: true,
    };
  }
  return {contents: src, didClear: false, didMerge: false};
}

/**
 * Copy Google TapAndPay SDK files to Android libs directory
 */
function copyGoogleTapAndPaySdk(projectRoot: string, sdkPath: string): void {
  const resolvedSdkPath = resolve(projectRoot, sdkPath);
  const androidLibsPath = join(projectRoot, 'android', 'libs');

  // Create libs directory if it doesn't exist
  if (!existsSync(androidLibsPath)) {
    mkdirSync(androidLibsPath, {recursive: true});
  }

  // Check if SDK path exists
  if (!existsSync(resolvedSdkPath)) {
    throw new Error(`Google TapAndPay SDK path not found: ${resolvedSdkPath}`);
  }

  const fileExtension = extname(resolvedSdkPath).toLowerCase();

  if (fileExtension === '.zip') {
    // Extract ZIP file contents using system unzip command
    try {
      execSync(`unzip -o "${resolvedSdkPath}" -d "${androidLibsPath}"`, {
        stdio: 'pipe',
      });
    } catch (error) {
      throw new Error(`Failed to extract ZIP file: ${error instanceof Error ? error.message : 'Unknown error'}`);
    }
  } else if (statSync(resolvedSdkPath).isDirectory()) {
    // Copy all files from SDK directory to libs
    const files = readdirSync(resolvedSdkPath);
    files.forEach((file) => {
      const srcFile = join(resolvedSdkPath, file);
      const destFile = join(androidLibsPath, file);

      if (statSync(srcFile).isFile()) {
        copyFileSync(srcFile, destFile);
      }
    });
  } else {
    // If it's a single file, copy it directly
    const fileName = resolvedSdkPath.split('/').pop() || 'google-tap-and-pay.aar';
    copyFileSync(resolvedSdkPath, join(androidLibsPath, fileName));
  }
}

/**
 * Config plugin for react-native-wallet
 * Configures native Android and iOS projects for wallet functionality
 */
const withReactNativeWallet: ConfigPlugin<ReactNativeWalletConfig> = (config, {googleTapAndPaySdkPath, enableApplePayProvisioning = true, walletExtension} = {}) => {
  // Configure iOS
  let modifiedConfig = withReactNativeWalletIOS(config, {
    enableApplePayProvisioning,
  });

  // Configure the iOS Wallet provisioning extension (P0-2 §4.7), if requested.
  if (walletExtension) {
    modifiedConfig = withWalletExtension(modifiedConfig, resolveExtensionConfig(walletExtension));
  }

  // Configure Android
  modifiedConfig = withReactNativeWalletAndroid(modifiedConfig, {
    googleTapAndPaySdkPath,
  });

  return modifiedConfig;
};

/**
 * Configure iOS for react-native-wallet
 */
const withReactNativeWalletIOS: ConfigPlugin<{
  enableApplePayProvisioning: boolean;
}> = (config, {enableApplePayProvisioning}) => {
  if (!enableApplePayProvisioning) {
    return config;
  }

  return withInfoPlist(config, (c) => {
    // Add Apple Pay In-App Provisioning entitlement
    // Following the structure from the documentation
    // eslint-disable-next-line no-param-reassign
    c.modResults['com.apple.developer.payment-pass-provisioning'] = true;

    return c;
  });
};

/**
 * Configure Android for react-native-wallet
 */
const withReactNativeWalletAndroid: ConfigPlugin<{
  googleTapAndPaySdkPath?: string;
}> = (config, {googleTapAndPaySdkPath}) => {
  if (!googleTapAndPaySdkPath) {
    return config;
  }

  return withProjectBuildGradle(config, (c) => {
    // Copy Google TapAndPay SDK files to android/libs
    copyGoogleTapAndPaySdk(c.modRequest.projectRoot, googleTapAndPaySdkPath);

    if (c.modResults.language === 'groovy') {
      // Configure gradle to use the local libs directory
      // This follows the pattern from react-native-wallet documentation
      const gradleMaven = `allprojects {
	repositories {
		google()
		maven { url "file://\${rootDir}/libs" }
	}
}`;
      // eslint-disable-next-line no-param-reassign
      c.modResults.contents = appendContents({
        comment: '//',
        newSrc: gradleMaven,
        src: c.modResults.contents,
        tag: 'react-native-wallet-libs-repository',
      }).contents;
    } else {
      throw new Error('Cannot add react-native-wallet maven repository because the build.gradle is not groovy');
    }
    return c;
  });
};

/**
 * Orchestrates the iOS Wallet provisioning extension (P0-2 §4.7):
 *  1. host-app App Group entitlement + Info.plist key
 *  2. generated extension files (Info.plist, entitlements, Swift subclass)
 *  3. the Xcode app-extension target
 *  4. the Podfile entry linking the WalletExtension subspec
 */
const withWalletExtension: ConfigPlugin<ResolvedExtensionConfig> = (config, ext) => {
  let c = withMainAppAppGroup(config, ext);
  c = withGeneratedExtensionFiles(c, ext);
  c = withExtensionXcodeTarget(c, ext);
  c = withExtensionPodfile(c, ext);

  // Sibling UI extension (P0-2 §4.7 UI extension). Shares the App Group set up
  // above by `withMainAppAppGroup`, so no extra entitlement wiring on the host
  // app is needed when auth is enabled.
  if (ext.auth) {
    c = withGeneratedAuthExtensionFiles(c, ext.auth);
    c = withAuthExtensionXcodeTarget(c, ext.auth);
    c = withAuthExtensionPodfile(c, ext.auth);
  }

  return c;
};

/** Adds the App Group to the host app's entitlements + the App Group id to its Info.plist. */
const withMainAppAppGroup: ConfigPlugin<ResolvedExtensionConfig> = (config, ext) => {
  let c = withEntitlementsPlist(config, (cfg) => {
    const key = 'com.apple.security.application-groups';
    const groups = (cfg.modResults[key] as string[] | undefined) ?? [];
    if (!groups.includes(ext.appGroup)) {
      groups.push(ext.appGroup);
    }
    // eslint-disable-next-line no-param-reassign
    cfg.modResults[key] = groups;
    return cfg;
  });

  // The host-app TurboModule reads the App Group id from this Info.plist key,
  // mirroring how the extension resolves it.
  c = withInfoPlist(c, (cfg) => {
    // eslint-disable-next-line no-param-reassign
    cfg.modResults[EXTENSION_DEFAULTS.appGroupInfoPlistKey] = ext.appGroup;
    return cfg;
  });

  return c;
};

/** Writes the extension's Info.plist, entitlements, and Swift subclass to ios/<targetName>/. */
const withGeneratedExtensionFiles: ConfigPlugin<ResolvedExtensionConfig> = (config, ext) =>
  withDangerousMod(config, [
    'ios',
    (cfg) => {
      const iosRoot = cfg.modRequest.platformProjectRoot;
      const targetDir = join(iosRoot, ext.targetName);
      if (!existsSync(targetDir)) {
        mkdirSync(targetDir, {recursive: true});
      }

      writeFileSync(join(targetDir, `${ext.targetName}-Info.plist`), buildExtensionInfoPlist(ext));
      writeFileSync(join(targetDir, `${ext.targetName}.entitlements`), buildExtensionEntitlements(ext));
      writeFileSync(join(targetDir, `${ext.className}.swift`), buildExtensionSwift(ext));

      return cfg;
    },
  ]);

/** Creates the app-extension target in the Xcode project and wires it to the host app. */
const withExtensionXcodeTarget: ConfigPlugin<ResolvedExtensionConfig> = (config, ext) =>
  withXcodeProject(config, (cfg) => {
    const project = cfg.modResults;

    // Idempotent — `expo prebuild` (without --clean) re-runs mods.
    if (project.pbxTargetByName(ext.targetName)) {
      return cfg;
    }

    const bundleId = `${cfg.ios?.bundleIdentifier ?? ''}${ext.bundleSuffix}`;
    addExtensionTarget(project, ext, bundleId);
    return cfg;
  });

/**
 * Adds a TOP-LEVEL `target '<name>' do ... end` for the WalletExtension to
 * the Podfile (sibling of the host app target, not nested).
 *
 * Why sibling and not nested: nesting inside the host target means the
 * extension's `target_definition` inherits everything from the host via the
 * CocoaPods parent chain — pods, search paths, linker flags
 * (`-framework "React"`, `-framework "hermes"` — App Store rejection
 * material for an app-extension binary), and crucially Expo Modules
 * autolinking (which generates an `ExpoModulesProvider.swift` with
 * `import ExpoCamera` / `import ExpoNotifications` / etc. that fail to
 * link in an extension). Every workaround for that inheritance — inherit!
 * :search_paths`, `inherit! :none, autolinking-manager stubs — either
 * leaks unwanted symbols into the extension or breaks pod resolution for
 * the extension's own pod.
 *
 * A top-level target avoids the inheritance entirely. CocoaPods finds the
 * host relationship from the Xcode project's `PBXTargetDependency` entry
 * (which `addTargetDependency` writes — see `addExtensionTarget` above) plus
 * the host's "Embed App Extensions" copy-files build phase, so the Podfile
 * doesn't need to express the embedding.
 */
const withExtensionPodfile: ConfigPlugin<ResolvedExtensionConfig> = (config, ext) =>
  withPodfile(config, (cfg) => {
    const tag = 'react-native-wallet-extension-target';
    const podBlock = [`target '${ext.targetName}' do`, `  pod 'react-native-wallet-extension', :path => '../node_modules/@darbpay/react-native-wallet'`, `end`].join('\n');

    // Strip any prior generated block from a previous prebuild — whether the
    // older version of this plugin placed it nested or at the top level — so
    // re-runs don't accumulate duplicate blocks.
    const stripped = (removeGeneratedContents(cfg.modResults.contents, tag) ?? cfg.modResults.contents).trimEnd();

    const header = createGeneratedHeaderComment(podBlock, tag, '#');
    const generated = [header, podBlock, `# @generated end ${tag}`].join('\n');

    // eslint-disable-next-line no-param-reassign
    cfg.modResults.contents = `${stripped}\n\n${generated}\n`;
    return cfg;
  });

// MARK: - File contents

function buildExtensionInfoPlist(ext: ResolvedExtensionConfig): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>${ext.targetName}</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
  <key>CFBundleShortVersionString</key>
  <string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key>
  <string>$(CURRENT_PROJECT_VERSION)</string>
  <key>${EXTENSION_DEFAULTS.appGroupInfoPlistKey}</key>
  <string>${ext.appGroup}</string>
  <key>${EXTENSION_DEFAULTS.encryptBaseUrlInfoPlistKey}</key>
  <string>${ext.encryptBaseUrl}</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>${EXTENSION_DEFAULTS.extensionPointIdentifier}</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).${ext.className}</string>
  </dict>
</dict>
</plist>
`;
}

function buildExtensionEntitlements(ext: ResolvedExtensionConfig): string {
  // `payment-pass-provisioning` is mandatory for any binary that hosts a
  // PKIssuerProvisioningExtension — without it the extension fails to register
  // with Wallet at runtime, and the binary is rejected on App Store submission.
  // The entitlement itself is Apple-issued: the matching App ID must have it
  // granted via the Apple Pay program before signing succeeds for distribution
  // builds (development signing typically works without).
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.payment-pass-provisioning</key>
  <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>${ext.appGroup}</string>
  </array>
</dict>
</plist>
`;
}

function buildExtensionSwift(ext: ResolvedExtensionConfig): string {
  // Module name matches the WalletExtension subspec's `module_name` in the
  // podspec — kept distinct from the Core subspec so the two modulemaps don't
  // collide in the Pods workspace. Don't change one side without the other.
  return `import PassKit
import react_native_wallet_extension

// Auto-generated by @darbpay/react-native-wallet (P0-2 §4.7).
// The handler logic lives in the library's WalletExtension subspec; this is the
// thin brand subclass the extension's Info.plist points to as its principal class.
@available(iOS 14.0, *)
@objc(${ext.className})
class ${ext.className}: WalletIssuerProvisioningExtensionHandler {}
`;
}

// MARK: - Auth (UI) extension generators

/** Writes the UI extension's Info.plist, entitlements, and Swift subclass to ios/<targetName>/. */
const withGeneratedAuthExtensionFiles: ConfigPlugin<ResolvedAuthExtensionConfig> = (config, ext) =>
  withDangerousMod(config, [
    'ios',
    (cfg) => {
      const iosRoot = cfg.modRequest.platformProjectRoot;
      const targetDir = join(iosRoot, ext.targetName);
      if (!existsSync(targetDir)) {
        mkdirSync(targetDir, {recursive: true});
      }

      writeFileSync(join(targetDir, `${ext.targetName}-Info.plist`), buildAuthExtensionInfoPlist(ext));
      writeFileSync(join(targetDir, `${ext.targetName}.entitlements`), buildAuthExtensionEntitlements(ext));
      writeFileSync(join(targetDir, `${ext.className}.swift`), buildAuthExtensionSwift(ext));

      return cfg;
    },
  ]);

/** Creates the UI app-extension target in the Xcode project. Reuses `addExtensionTarget` because the target type and build settings are identical to the non-UI extension — only the bundle id, principal class, and Info.plist's extension-point identifier differ (the latter is baked into the generated Info.plist, not the Xcode target). */
const withAuthExtensionXcodeTarget: ConfigPlugin<ResolvedAuthExtensionConfig> = (config, ext) =>
  withXcodeProject(config, (cfg) => {
    const project = cfg.modResults;

    if (project.pbxTargetByName(ext.targetName)) {
      return cfg;
    }

    const bundleId = `${cfg.ios?.bundleIdentifier ?? ''}${ext.bundleSuffix}`;
    addExtensionTarget(project, {targetName: ext.targetName, className: ext.className}, bundleId);
    return cfg;
  });

/** Adds a TOP-LEVEL `target '<auth target>' do ... end` for the UI extension to the Podfile. See `withExtensionPodfile` above for the long-form rationale on why this is sibling (not nested under the host target). */
const withAuthExtensionPodfile: ConfigPlugin<ResolvedAuthExtensionConfig> = (config, ext) =>
  withPodfile(config, (cfg) => {
    const tag = 'react-native-wallet-extension-auth-target';
    const podBlock = [`target '${ext.targetName}' do`, `  pod 'react-native-wallet-extension-auth', :path => '../node_modules/@darbpay/react-native-wallet'`, `end`].join('\n');

    const stripped = (removeGeneratedContents(cfg.modResults.contents, tag) ?? cfg.modResults.contents).trimEnd();
    const header = createGeneratedHeaderComment(podBlock, tag, '#');
    const generated = [header, podBlock, `# @generated end ${tag}`].join('\n');

    // eslint-disable-next-line no-param-reassign
    cfg.modResults.contents = `${stripped}\n\n${generated}\n`;
    return cfg;
  });

// MARK: - Auth (UI) extension file contents

function buildAuthExtensionInfoPlist(ext: ResolvedAuthExtensionConfig): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>${ext.targetName}</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
  <key>CFBundleShortVersionString</key>
  <string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key>
  <string>$(CURRENT_PROJECT_VERSION)</string>
  <key>${EXTENSION_DEFAULTS.appGroupInfoPlistKey}</key>
  <string>${ext.appGroup}</string>
  <key>${AUTH_EXTENSION_DEFAULTS.clerkPublishableKeyInfoPlistKey}</key>
  <string>${ext.clerkPublishableKey}</string>
  <key>${AUTH_EXTENSION_DEFAULTS.jwtTemplateInfoPlistKey}</key>
  <string>${ext.jwtTemplate}</string>
  <key>${EXTENSION_DEFAULTS.encryptBaseUrlInfoPlistKey}</key>
  <string>${ext.encryptBaseUrl}</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>${AUTH_EXTENSION_DEFAULTS.extensionPointIdentifier}</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).${ext.className}</string>
  </dict>
</dict>
</plist>
`;
}

function buildAuthExtensionEntitlements(ext: ResolvedAuthExtensionConfig): string {
  // Identical to the non-UI extension — see `buildExtensionEntitlements` for
  // the rationale on `payment-pass-provisioning`. Both extensions share the
  // same App Group container as the sole inter-extension state channel.
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.payment-pass-provisioning</key>
  <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>${ext.appGroup}</string>
  </array>
</dict>
</plist>
`;
}

function buildAuthExtensionSwift(ext: ResolvedAuthExtensionConfig): string {
  // Module name matches the WalletExtensionAuth pod's name — distinct from
  // both the Core pod and the non-UI extension pod so the modulemaps don't
  // collide in the Pods workspace. Don't change one side without the other.
  return `import PassKit
import UIKit
import react_native_wallet_extension_auth

// Auto-generated by @darbpay/react-native-wallet (P0-2 §4.7 UI extension).
// The view-controller logic lives in the WalletExtensionAuth pod; this is the
// thin brand subclass the extension's Info.plist points to as its principal class.
@available(iOS 14.0, *)
@objc(${ext.className})
class ${ext.className}: WalletAuthorizationProvidingViewController {}
`;
}

// MARK: - Xcode target creation
//
// node-xcode's addTarget('app_extension') creates the target, its build
// configuration list, the product file, and the "Embed App Extensions" copy
// phase in the host target. We add the Sources/Frameworks/Resources phases, the
// target dependency, the file group, and the target-specific build settings.
// This portion can only be verified by running `expo prebuild` on macOS.
function addExtensionTarget(project: XcodeProject, ext: {targetName: string; className: string}, bundleId: string): void {
  const {targetName, className} = ext;
  const swiftName = `${className}.swift`;
  const infoPlistName = `${targetName}-Info.plist`;
  const entitlementsName = `${targetName}.entitlements`;

  // Group holding the generated files, nested under the project's main group.
  const group = project.addPbxGroup([swiftName, infoPlistName, entitlementsName], targetName, targetName);
  const groups = project.hash.project.objects.PBXGroup;
  Object.keys(groups).forEach((key) => {
    const candidate = groups[key];
    const isMainGroup = typeof candidate === 'object' && candidate.name === undefined && candidate.path === undefined && Array.isArray(candidate.children);
    if (!isMainGroup) {
      return;
    }
    project.addToPbxGroup(group.uuid, key);
  });

  // Create the target (config list + product + embed phase in host target).
  const target = project.addTarget(targetName, 'app_extension', targetName, bundleId);

  // Build phases for the new target.
  project.addBuildPhase([swiftName], 'PBXSourcesBuildPhase', 'Sources', target.uuid);
  project.addBuildPhase([], 'PBXResourcesBuildPhase', 'Resources', target.uuid);
  project.addBuildPhase([], 'PBXFrameworksBuildPhase', 'Frameworks', target.uuid);

  // Host app depends on the extension so it builds + embeds.
  // node-xcode's `addTargetDependency` silently no-ops if the project has no
  // existing `PBXTargetDependency` / `PBXContainerItemProxy` sections (see
  // node_modules/xcode/lib/pbxProject.js — the body is guarded by
  // `if (pbxContainerItemProxySection && pbxTargetDependencySection)`).
  // Expo-generated projects start without either, so without seeding them
  // first the call produces no entries and CocoaPods can't see the host →
  // extension relationship, failing with
  // "Unable to find host target(s) for <ext>. Please add the host targets…".
  const projectObjects = project.hash.project.objects;
  projectObjects.PBXTargetDependency = projectObjects.PBXTargetDependency || {};
  projectObjects.PBXContainerItemProxy = projectObjects.PBXContainerItemProxy || {};
  project.addTargetDependency(project.getFirstTarget().uuid, [target.uuid]);

  // Target-specific build settings.
  //
  // `IPHONEOS_DEPLOYMENT_TARGET` is intentionally NOT set here — the target
  // inherits the project-level deployment target, which CocoaPods uses for
  // every pod in the workspace (including this extension's own pod). Setting
  // it to a lower value than the project causes "compiling for iOS X, but
  // module 'react_native_wallet_extension' has a minimum deployment target of
  // iOS Y" because Swift refuses to import a `.swiftmodule` built for a
  // higher OS than the consumer. The iOS 14.0 floor required by
  // PKIssuerProvisioningExtensionHandler is enforced separately via
  // `s.platforms = { :ios => "14.0" }` in the podspec, and via
  // `@available(iOS 14.0, *)` on the generated subclass.
  setTargetBuildSettings(project, target.uuid, {
    SWIFT_VERSION: '5.0',
    TARGETED_DEVICE_FAMILY: '"1,2"',
    GENERATE_INFOPLIST_FILE: 'NO',
    INFOPLIST_FILE: `"${targetName}/${infoPlistName}"`,
    CODE_SIGN_ENTITLEMENTS: `"${targetName}/${entitlementsName}"`,
    PRODUCT_BUNDLE_IDENTIFIER: `"${bundleId}"`,
    MARKETING_VERSION: '1.0',
    CURRENT_PROJECT_VERSION: '1',
    SWIFT_EMIT_LOC_STRINGS: 'YES',
  });
}

/** Applies build settings to every XCBuildConfiguration of a target's config list. */
function setTargetBuildSettings(project: XcodeProject, targetUuid: string, settings: Record<string, string>): void {
  const nativeTargets = project.pbxNativeTargetSection();
  const target = nativeTargets[targetUuid];
  if (!target) {
    return;
  }
  const configListUuid = target.buildConfigurationList;
  const configLists = project.pbxXCConfigurationList();
  const configList = configLists[configListUuid];
  const buildConfigs = project.pbxXCBuildConfigurationSection();

  configList.buildConfigurations.forEach((entry: {value: string}) => {
    const config = buildConfigs[entry.value];
    if (!config || typeof config !== 'object' || !config.buildSettings) {
      return;
    }
    Object.assign(config.buildSettings, settings);
  });
}

export default createRunOncePlugin(withReactNativeWallet, 'ReactNativeWallet', '0.2.18');
