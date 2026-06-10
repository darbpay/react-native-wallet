import type {TurboModule} from 'react-native';
import {TurboModuleRegistry} from 'react-native';

type AndroidWalletData = {
  deviceID: string;
  walletAccountID: string;
};

type CardStatus = 'not found' | 'requireActivation' | 'pending' | 'active' | 'suspended' | 'deactivated';

type Platform = 'android' | 'ios';

type UserAddress = {
  name: string;
  addressOne: string;
  addressTwo?: string;
  administrativeArea: string;
  locality: string;
  countryCode: string;
  postalCode: string;
  phoneNumber: string;
};

type AndroidCardData = {
  network: string;
  opaquePaymentCard: string;
  cardHolderName: string;
  lastDigits: string;
  userAddress: UserAddress;
};

type AndroidResumeCardData = {
  network: string;
  tokenReferenceID: string;
  cardHolderName?: string;
  lastDigits?: string;
};

type IOSCardData = {
  network: string;
  cardHolderName: string;
  lastDigits: string;
  cardDescription: string;
  // Apple FPANID (`primaryAccountIdentifier`), from the PNO after a card's
  // first provisioning. When set, Apple Wallet scopes the provisioning UI to
  // the devices that can still receive the pass — e.g. "Add to Apple Watch"
  // for a card already on the iPhone (Apple §7.6). Omit on the first add.
  primaryAccountIdentifier?: string;
};

type onCardActivatedPayload = {
  tokenId: string;
  status: 'activated' | 'canceled' | 'requiresActivation' | 'pending' | 'suspended' | 'deactivated' | 'unknown';
};

type onCardRemovedPayload = {
  tokenId: string;
  passTypeIdentifier: string;
};

type IOSAddPaymentPassData = {
  status: number;
  nonce: string;
  nonceSignature: string;
  certificates: string[];
};

type IOSEncryptPayload = {
  encryptedPassData: string;
  activationData: string;
  ephemeralPublicKey: string;
};

type TokenizationStatus = 'canceled' | 'success' | 'error';

type TokenInfo = {
  identifier: string;
  lastDigits: string;
  tokenState: number;
  // iOS only. true when this pass lives on a paired Apple Watch
  // (`PKPassLibrary.remoteSecureElementPasses`), false for iPhone local passes.
  // Always false on Android.
  isRemote?: boolean;
};

/**
 * A card the host app marks as eligible for the Wallet-app-initiated
 * provisioning extension (P0-2 §4.7). Cached in the App Group container for the
 * extension to read.
 *
 * Two-identifier rule:
 *  - `cardId` — DarbPay's internal card id. Used as the PassKit entry
 *    identifier AND as the `{cardId}` segment of the encrypt endpoint.
 *  - `panId` — Apple `primaryAccountIdentifier` (from the Emcrey `token.added`
 *    webhook). Used ONLY to dedupe against passes already on the device/Watch.
 *    Null until the card has been provisioned at least once.
 */
type EligibilityCard = {
  cardId: string;
  panId?: string | null;
  last4: string;
  displayName: string;
  cardholderName: string;
  network: string;
  eligibleAt: string;
};

export interface Spec extends TurboModule {
  checkWalletAvailability(): Promise<boolean>;
  ensureGoogleWalletInitialized(): Promise<boolean>;
  getSecureWalletInfo(): Promise<AndroidWalletData>;
  getCardStatusBySuffix(last4Digits: string): Promise<number>;
  getCardStatusByIdentifier(identifier: string, tsp: string): Promise<number>;
  canAddCardWithIdentifier(identifier: string): Promise<boolean>;
  // iOS only. true when this iPhone is paired with an Apple Watch (via
  // `WCSession.isPaired`). Used to decide whether to surface "Add to Apple
  // Watch". Resolves false on Android / when WatchConnectivity is unsupported.
  isWatchPaired(): Promise<boolean>;
  debugPassLibraryState(): Promise<{
    canAddPaymentPass: boolean;
    allPassesCount: number;
    paymentPassesCount: number;
    remoteSecureElementPassesCount: number;
    allPassTypeIdentifiers: string[];
  }>;
  addCardToGoogleWallet(cardData: AndroidCardData): Promise<number>;
  resumeAddCardToGoogleWallet(cardData: AndroidResumeCardData): Promise<number>;
  listTokens(): Promise<TokenInfo[]>;
  IOSPresentAddPaymentPassView(cardData: IOSCardData): Promise<IOSAddPaymentPassData>;
  IOSHandleAddPaymentPassResponse(payload: IOSEncryptPayload): Promise<IOSAddPaymentPassData | null>;
  // Wallet-app-initiated provisioning extension cache (P0-2 §4.7, iOS only).
  // `cardsJson` is a JSON-encoded EligibilityCard[]; the native layer owns the
  // on-disk schema (incl. the `writtenAt` timestamp) via Codable.
  setWalletExtensionEligibleCards(cardsJson: string): Promise<void>;
  clearWalletExtensionEligibleCards(): Promise<void>;
  setWalletExtensionAuthToken(token: string, expiresAtMs: number): Promise<void>;
  clearWalletExtensionAuthToken(): Promise<void>;
  setWalletExtensionCardArt(cardId: string, scale: number, pngBase64: string): Promise<void>;
  addListener: (eventType: string) => void;
  removeListeners: (count: number) => void;
}

const PACKAGE_NAME = '@expensify/react-native-wallet';
// Try catch block to prevent crashing in case the module is not linked.
// Especialy useful for builds where Google SDK is not available
// eslint-disable-next-line import/no-mutable-exports
let Wallet: Spec | undefined;
try {
  Wallet = TurboModuleRegistry.getEnforcing<Spec>('RNWallet');
} catch (error) {
  if (error instanceof Error) {
    // eslint-disable-next-line no-console
    console.warn(`[${PACKAGE_NAME}] Failed to load Wallet module, ${error.message}`);
  }
}
export default Wallet;
export {PACKAGE_NAME};
export type {
  AndroidCardData,
  AndroidResumeCardData,
  IOSCardData,
  AndroidWalletData,
  CardStatus,
  UserAddress,
  onCardActivatedPayload,
  onCardRemovedPayload,
  Platform,
  IOSAddPaymentPassData,
  IOSEncryptPayload,
  TokenizationStatus,
  TokenInfo,
  EligibilityCard,
};
