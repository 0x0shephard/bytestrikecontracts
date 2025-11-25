import * as dotenv from 'dotenv';
import { BotConfig } from './types';

dotenv.config();

function getEnvVar(key: string, defaultValue?: string): string {
  const value = process.env[key] || defaultValue;
  if (!value) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
  return value;
}

export const config: BotConfig = {
  sepoliaRpcUrl: getEnvVar('SEPOLIA_RPC_URL'),
  masterWalletPrivateKey: getEnvVar('MASTER_WALLET_PRIVATE_KEY'),
  googleEmail: getEnvVar('GOOGLE_EMAIL'),
  googlePassword: getEnvVar('GOOGLE_PASSWORD'),
  faucetWalletAddress: getEnvVar('FAUCET_WALLET_ADDRESS'),
  port: parseInt(getEnvVar('PORT', '3001'), 10),
  claimIntervalHours: parseInt(getEnvVar('CLAIM_INTERVAL_HOURS', '24'), 10),
  distributionAmount: getEnvVar('DISTRIBUTION_AMOUNT', '0.04'), // 0.04 ETH per user
  minMasterBalance: getEnvVar('MIN_MASTER_BALANCE', '0.1'), // Minimum balance to keep
  maxRequestsPerWalletPerDay: parseInt(getEnvVar('MAX_REQUESTS_PER_WALLET_PER_DAY', '1'), 10),
  maxRequestsPerIpPerDay: parseInt(getEnvVar('MAX_REQUESTS_PER_IP_PER_DAY', '3'), 10),
  minWalletBalanceThreshold: getEnvVar('MIN_WALLET_BALANCE_THRESHOLD', '0.05'), // Only send if user has < 0.05 ETH
  headless: getEnvVar('HEADLESS', 'true') === 'true',
};

export const GOOGLE_FAUCET_URL = 'https://cloud.google.com/application/web3/faucet/ethereum/sepolia';
export const DATA_DIR = './data';
export const REQUESTS_FILE = `${DATA_DIR}/requests.json`;
export const CLAIMS_FILE = `${DATA_DIR}/claims.json`;
export const RATE_LIMIT_FILE = `${DATA_DIR}/rate-limits.json`;
