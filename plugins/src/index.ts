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
  extensionPointIdentifier: 'com.apple.PassKit.issuer-provisioning-extension',
} as const;

type ResolvedExtensionConfig = Required<Omit<WalletExtensionConfig, 'bundleSuffix' | 'targetName' | 'className'>> &
  Required<Pick<WalletExtensionConfig, 'bundleSuffix' | 'targetName' | 'className'>>;

function resolveExtensionConfig(config: WalletExtensionConfig): ResolvedExtensionConfig {
  return {
    appGroup: config.appGroup,
    encryptBaseUrl: config.encryptBaseUrl,
    bundleSuffix: config.bundleSuffix ?? EXTENSION_DEFAULTS.bundleSuffix,
    targetName: config.targetName ?? EXTENSION_DEFAULTS.targetName,
    className: config.className ?? EXTENSION_DEFAULTS.className,
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

/** Adds `target '<name>' do pod 'react-native-wallet/WalletExtension' end` to the Podfile. */
const withExtensionPodfile: ConfigPlugin<ResolvedExtensionConfig> = (config, ext) =>
  withPodfile(config, (cfg) => {
    const podBlock = `target '${ext.targetName}' do\n  pod 'react-native-wallet/WalletExtension', :path => '../node_modules/@darbpay/react-native-wallet'\nend`;
    // eslint-disable-next-line no-param-reassign
    cfg.modResults.contents = appendContents({
      comment: '#',
      newSrc: podBlock,
      src: cfg.modResults.contents,
      tag: 'react-native-wallet-extension-target',
    }).contents;
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
  // NOTE (master spec open-question #1): the extension may also need
  // `com.apple.developer.payment-pass-provisioning` and/or its own provisioning
  // profile depending on how Apple scopes the App ID. Confirm with the Apple
  // Developer account holder; add the key here if required.
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>${ext.appGroup}</string>
  </array>
</dict>
</plist>
`;
}

function buildExtensionSwift(ext: ResolvedExtensionConfig): string {
  return `import PassKit
import react_native_wallet

// Auto-generated by @darbpay/react-native-wallet (P0-2 §4.7).
// The handler logic lives in the library's WalletExtension subspec; this is the
// thin brand subclass the extension's Info.plist points to as its principal class.
@available(iOS 14.0, *)
@objc(${ext.className})
class ${ext.className}: WalletIssuerProvisioningExtensionHandler {}
`;
}

// MARK: - Xcode target creation
//
// node-xcode's addTarget('app_extension') creates the target, its build
// configuration list, the product file, and the "Embed App Extensions" copy
// phase in the host target. We add the Sources/Frameworks/Resources phases, the
// target dependency, the file group, and the target-specific build settings.
// This portion can only be verified by running `expo prebuild` on macOS.
function addExtensionTarget(project: XcodeProject, ext: ResolvedExtensionConfig, bundleId: string): void {
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
  project.addTargetDependency(project.getFirstTarget().uuid, [target.uuid]);

  // Target-specific build settings.
  setTargetBuildSettings(project, target.uuid, {
    IPHONEOS_DEPLOYMENT_TARGET: '14.0',
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

export default createRunOncePlugin(withReactNativeWallet, 'ReactNativeWallet', '0.2.0');
