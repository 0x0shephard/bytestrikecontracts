export interface FaucetRequest {
  walletAddress: string;
  ipAddress?: string;
  timestamp: number;
  status: 'pending' | 'approved' | 'completed' | 'rejected';
  txHash?: string;
  amount?: string;
}

export interface FaucetClaim {
  timestamp: number;
  amount: string;
  txHash?: string;
  success: boolean;
  error?: string;
}

export interface RateLimitEntry {
  walletAddress?: string;
  ipAddress?: string;
  lastRequestTime: number;
  requestCount: number;
}

export interface BotConfig {
  sepoliaRpcUrl: string;
  masterWalletPrivateKey: string;
  googleEmail: string;
  googlePassword: string;
  faucetWalletAddress: string;
  port: number;
  claimIntervalHours: number;
  distributionAmount: string;
  minMasterBalance: string;
  maxRequestsPerWalletPerDay: number;
  maxRequestsPerIpPerDay: number;
  minWalletBalanceThreshold: string;
  headless: boolean;
}

export interface DistributionResult {
  success: boolean;
  txHash?: string;
  error?: string;
  amount?: string;
}
