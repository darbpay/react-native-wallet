/* eslint-disable @lwc/lwc/no-async-await */
import {NativeEventEmitter, Platform} from 'react-native';
import type {EmitterSubscription} from 'react-native';
import Wallet, {PACKAGE_NAME} from './NativeWallet';
import type {
  TokenizationStatus,
  AndroidCardData,
  AndroidResumeCardData,
  CardStatus,
  IOSCardData,
  IOSEncryptPayload,
  AndroidWalletData,
  onCardActivatedPayload,
  onCardRemovedPayload,
  IOSAddPaymentPassData,
  TokenInfo,
  EligibilityCard,
} from './NativeWallet';
import {getCardState, getTokenizationStatus} from './utils';
import AddToWalletButton from './AddToWalletButton';

function getModuleLinkingRejection() {
  return Promise.reject(new Error(`Failed to load Wallet module, make sure to link ${PACKAGE_NAME} correctly`));
}

type WalletErrorDetails = {
  code?: string;
  errorDomain?: string;
  errorCode?: number;
  errorReason?: string;
  errorDescription?: string;
  failureReason?: string;
  recoverySuggestion?: string;
  underlyingDomain?: string;
  underlyingCode?: number;
  underlyingDescription?: string;
};

class WalletError extends Error {
  code?: string;

  errorDomain?: string;

  errorCode?: number;

  errorReason?: string;

  errorDescription?: string;

  failureReason?: string;

  recoverySuggestion?: string;

  underlyingDomain?: string;

  underlyingCode?: number;

  underlyingDescription?: string;

  cause?: unknown;

  constructor(message: string, details: WalletErrorDetails, cause?: unknown) {
    super(message);
    this.name = 'WalletError';
    this.cause = cause;
    Object.assign(this, details);
  }
}

function toWalletError(err: unknown): WalletError {
  // React Native rejects from native modules surface as objects with `code`, `message`, and
  // `userInfo` (the NSError userInfo dictionary). Pull the structured fields up so callers
  // can branch on `errorReason` / `errorCode` directly without poking into userInfo.
  const e = err as {code?: string; message?: string; userInfo?: Record<string, unknown>} | undefined;
  const userInfo = e?.userInfo ?? {};
  const details: WalletErrorDetails = {
    code: e?.code,
    errorDomain: userInfo.errorDomain as string | undefined,
    errorCode: userInfo.errorCode as number | undefined,
    errorReason: userInfo.errorReason as string | undefined,
    errorDescription: userInfo.errorDescription as string | undefined,
    failureReason: userInfo.failureReason as string | undefined,
    recoverySuggestion: userInfo.recoverySuggestion as string | undefined,
    underlyingDomain: userInfo.underlyingDomain as string | undefined,
    underlyingCode: userInfo.underlyingCode as number | undefined,
    underlyingDescription: userInfo.underlyingDescription as string | undefined,
  };
  const message = e?.message || details.errorDescription || 'Wallet operation failed';
  return new WalletError(message, details, err);
}

const eventEmitter = new NativeEventEmitter(Wallet);

function addListener<T = onCardActivatedPayload | onCardRemovedPayload>(event: string, callback: (data: T) => void): EmitterSubscription {
  return eventEmitter.addListener(event, callback);
}

function removeListener(subscription: EmitterSubscription): void {
  subscription.remove();
}

function checkWalletAvailability(): Promise<boolean> {
  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  return Wallet.checkWalletAvailability();
}

async function getSecureWalletInfo(): Promise<AndroidWalletData> {
  if (Platform.OS === 'ios') {
    throw new Error('getSecureWalletInfo is not available on iOS');
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  const isWalletInitialized = await Wallet.ensureGoogleWalletInitialized();
  if (!isWalletInitialized) {
    throw new Error('Wallet could not be initialized');
  }

  return Wallet.getSecureWalletInfo();
}

async function getCardStatusBySuffix(last4Digits: string): Promise<CardStatus> {
  if (!Wallet) {
    return getModuleLinkingRejection();
  }

  const cardState = await Wallet.getCardStatusBySuffix(last4Digits);
  return getCardState(cardState);
}

/**
 * Returns the state of a card based on a platform-specific identifier.
 * @param identifier - The card identifier. On Android, it's `Token Reference ID` and on iOS, it's `Primary Account Identifier`
 * @param tsp - The Token Service Provider, e.g. `VISA`, `MASTERCARD`
 * @returns CardStatus - The card status
 */
async function getCardStatusByIdentifier(identifier: string, tsp: string): Promise<CardStatus> {
  if (!Wallet) {
    return getModuleLinkingRejection();
  }

  const tokenState = await Wallet.getCardStatusByIdentifier(identifier, tsp.toUpperCase());
  return getCardState(tokenState);
}

/**
 * iOS only. Preferred per Apple §7.5 — wraps
 * `PKPassLibrary.canAddSecureElementPass(primaryAccountIdentifier:)`. Returns
 * `true` only when the card is not yet provisioned to this iPhone or any
 * paired Apple Watch, i.e. when the Add to Apple Wallet button should be
 * shown. Resolves `false` on Android (Google Wallet has its own checks).
 *
 * @param identifier - Apple `primaryAccountIdentifier` (FPANID), available
 *   from the PNO after the first provisioning of a card.
 */
async function canAddCardWithIdentifier(identifier: string): Promise<boolean> {
  if (Platform.OS === 'android') {
    return false;
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }

  return Wallet.canAddCardWithIdentifier(identifier);
}

/**
 * iOS only. Resolves `true` when this iPhone is paired with an Apple Watch
 * (`WCSession.isPaired`). Use it to decide whether to surface an "Add to Apple
 * Watch" label for a card already on the iPhone. More reliable than inspecting
 * `listTokens()` for remote passes, which is empty when the Watch is paired but
 * holds no passes yet. Resolves `false` on Android.
 */
async function isWatchPaired(): Promise<boolean> {
  if (Platform.OS === 'android') {
    return false;
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }

  return Wallet.isWatchPaired();
}

/**
 * iOS-only diagnostic. Snapshots every counter PassKit exposes about pass
 * visibility so callers can distinguish between:
 *   - no entitlement / not on Apple's allow list — `allPassesCount === 0`
 *     and `canAddPaymentPass` may be false. Wallet hides everything from
 *     this build.
 *   - entitlement OK but PNO `associatedApplicationIdentifiers` mismatch —
 *     `allPassesCount > 0` (boarding passes etc.) but `paymentPassesCount === 0`.
 *   - Simulator — always returns zeros, no Secure Element.
 *
 * Resolves zeros on Android (no PassKit).
 */
type PassLibraryDebugState = {
  canAddPaymentPass: boolean;
  allPassesCount: number;
  paymentPassesCount: number;
  remoteSecureElementPassesCount: number;
  allPassTypeIdentifiers: string[];
};

async function debugPassLibraryState(): Promise<PassLibraryDebugState> {
  if (Platform.OS === 'android') {
    return {
      canAddPaymentPass: false,
      allPassesCount: 0,
      paymentPassesCount: 0,
      remoteSecureElementPassesCount: 0,
      allPassTypeIdentifiers: [],
    };
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }

  return Wallet.debugPassLibraryState();
}

async function addCardToGoogleWallet(cardData: AndroidCardData): Promise<TokenizationStatus> {
  if (Platform.OS === 'ios') {
    throw new Error('addCardToGoogleWallet is not available on iOS');
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  const isWalletInitialized = await Wallet.ensureGoogleWalletInitialized();
  if (!isWalletInitialized) {
    throw new Error('Wallet could not be initialized');
  }
  const tokenizationStatus = await Wallet.addCardToGoogleWallet(cardData);
  return getTokenizationStatus(tokenizationStatus);
}

async function resumeAddCardToGoogleWallet(cardData: AndroidResumeCardData): Promise<TokenizationStatus> {
  if (Platform.OS === 'ios') {
    throw new Error('resumeAddCardToGoogleWallet is not available on iOS');
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  const isWalletInitialized = await Wallet.ensureGoogleWalletInitialized();
  if (!isWalletInitialized) {
    throw new Error('Wallet could not be initialized');
  }
  const tokenizationStatus = await Wallet.resumeAddCardToGoogleWallet(cardData);
  return getTokenizationStatus(tokenizationStatus);
}

async function listTokens(): Promise<TokenInfo[]> {
  if (!Wallet) {
    return getModuleLinkingRejection();
  }

  if (Platform.OS === 'android') {
    const isWalletInitialized = await Wallet.ensureGoogleWalletInitialized();
    if (!isWalletInitialized) {
      throw new Error('Wallet could not be initialized');
    }
  }

  return Wallet.listTokens();
}

async function addCardToAppleWallet(
  cardData: IOSCardData,
  issuerEncryptPayloadCallback: (nonce: string, nonceSignature: string, certificate: string[]) => Promise<IOSEncryptPayload>,
): Promise<TokenizationStatus> {
  if (Platform.OS === 'android') {
    throw new Error('addCardToAppleWallet is not available on Android');
  }

  let passData: IOSAddPaymentPassData | undefined;
  try {
    passData = await Wallet?.IOSPresentAddPaymentPassView(cardData);
  } catch (err) {
    throw toWalletError(err);
  }
  if (!passData || passData.status !== 0) {
    return getTokenizationStatus(passData?.status || -1);
  }

  async function addPaymentPassToWallet(paymentPassData: IOSAddPaymentPassData): Promise<number> {
    const responseData = await issuerEncryptPayloadCallback(paymentPassData.nonce, paymentPassData.nonceSignature, paymentPassData.certificates);
    let response: IOSAddPaymentPassData | null | undefined;
    try {
      response = await Wallet?.IOSHandleAddPaymentPassResponse(responseData);
    } catch (err) {
      throw toWalletError(err);
    }
    // Response is null when a pass is successfully added to the wallet or the user cancels the process
    // In case the user presses the `Try again` option, new pass data is returned, and it should reenter the function
    if (response) {
      return addPaymentPassToWallet(response);
    }
    return 0;
  }
  const status = await addPaymentPassToWallet(passData);
  return getTokenizationStatus(status);
}

/**
 * Wallet-app-initiated provisioning extension cache (P0-2 §4.7) — iOS only.
 *
 * The host app calls these to keep the App Group container fresh so the
 * PKIssuerProvisioningExtension can answer Apple's eligibility queries without
 * the app running. See `EligibilityCard` for the two-identifier rule.
 */
async function setWalletExtensionEligibleCards(cards: EligibilityCard[]): Promise<void> {
  if (Platform.OS === 'android') {
    throw new Error('setWalletExtensionEligibleCards is not available on Android');
  }
  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  try {
    // Native owns the on-disk schema (incl. writtenAt) via Codable; we only
    // hand over the cards array as JSON.
    await Wallet.setWalletExtensionEligibleCards(JSON.stringify(cards));
  } catch (err) {
    throw toWalletError(err);
  }
}

async function clearWalletExtensionEligibleCards(): Promise<void> {
  if (Platform.OS === 'android') {
    throw new Error('clearWalletExtensionEligibleCards is not available on Android');
  }
  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  try {
    await Wallet.clearWalletExtensionEligibleCards();
  } catch (err) {
    throw toWalletError(err);
  }
}

/**
 * Persists the Clerk session token and its absolute expiry (ms since epoch) to
 * the shared keychain. The extension uses the expiry to judge token validity
 * locally within its sub-100ms status budget.
 */
async function setWalletExtensionAuthToken(token: string, expiresAtMs: number): Promise<void> {
  if (Platform.OS === 'android') {
    throw new Error('setWalletExtensionAuthToken is not available on Android');
  }
  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  try {
    await Wallet.setWalletExtensionAuthToken(token, expiresAtMs);
  } catch (err) {
    throw toWalletError(err);
  }
}

async function clearWalletExtensionAuthToken(): Promise<void> {
  if (Platform.OS === 'android') {
    throw new Error('clearWalletExtensionAuthToken is not available on Android');
  }
  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  try {
    await Wallet.clearWalletExtensionAuthToken();
  } catch (err) {
    throw toWalletError(err);
  }
}

/**
 * Persists a card-art PNG thumbnail at the given screen scale (1, 2, or 3).
 * `pngBase64` is the raw base64 of the PNG bytes (no data: URI prefix).
 */
async function setWalletExtensionCardArt(cardId: string, scale: 1 | 2 | 3, pngBase64: string): Promise<void> {
  if (Platform.OS === 'android') {
    throw new Error('setWalletExtensionCardArt is not available on Android');
  }
  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  try {
    await Wallet.setWalletExtensionCardArt(cardId, scale, pngBase64);
  } catch (err) {
    throw toWalletError(err);
  }
}

export type {
  AndroidCardData,
  AndroidWalletData,
  CardStatus,
  IOSEncryptPayload,
  IOSCardData,
  IOSAddPaymentPassData,
  onCardActivatedPayload,
  onCardRemovedPayload,
  TokenizationStatus,
  TokenInfo,
  EligibilityCard,
};
export {
  AddToWalletButton,
  checkWalletAvailability,
  getSecureWalletInfo,
  getCardStatusBySuffix,
  getCardStatusByIdentifier,
  canAddCardWithIdentifier,
  isWatchPaired,
  debugPassLibraryState,
  addCardToGoogleWallet,
  resumeAddCardToGoogleWallet,
  listTokens,
  addCardToAppleWallet,
  setWalletExtensionEligibleCards,
  clearWalletExtensionEligibleCards,
  setWalletExtensionAuthToken,
  clearWalletExtensionAuthToken,
  setWalletExtensionCardArt,
  addListener,
  removeListener,
  WalletError,
};
