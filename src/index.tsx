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
  if (Platform.OS === 'ios') {
    return Promise.resolve([]);
  }

  if (!Wallet) {
    return getModuleLinkingRejection();
  }
  const isWalletInitialized = await Wallet.ensureGoogleWalletInitialized();
  if (!isWalletInitialized) {
    throw new Error('Wallet could not be initialized');
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
};
export {
  AddToWalletButton,
  checkWalletAvailability,
  getSecureWalletInfo,
  getCardStatusBySuffix,
  getCardStatusByIdentifier,
  addCardToGoogleWallet,
  resumeAddCardToGoogleWallet,
  listTokens,
  addCardToAppleWallet,
  addListener,
  removeListener,
  WalletError,
};
