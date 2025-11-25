import express, { Request, Response } from 'express';
import cors from 'cors';
import { config } from './config';
import { ETHDistributor } from './distributor';
import {
  initializeStorage,
  addRequest,
  updateRequest,
  getRequestByWallet,
  getRateLimit,
  updateRateLimit,
  loadRequests
} from './storage';
import { FaucetRequest } from './types';

const app = express();
const distributor = new ETHDistributor();

// Middleware
app.use(cors());
app.use(express.json());

// Initialize storage
initializeStorage();

/**
 * Rate limiting check
 */
function checkRateLimit(walletAddress: string, ipAddress?: string): { allowed: boolean; reason?: string } {
  // Check wallet-based rate limit
  const walletLimit = getRateLimit(walletAddress);
  if (walletLimit && walletLimit.requestCount >= config.maxRequestsPerWalletPerDay) {
    const hoursLeft = Math.ceil((24 * 60 * 60 * 1000 - (Date.now() - walletLimit.lastRequestTime)) / (60 * 60 * 1000));
    return {
      allowed: false,
      reason: `Rate limit exceeded for wallet. Try again in ${hoursLeft} hours.`,
    };
  }

  // Check IP-based rate limit
  if (ipAddress) {
    const ipLimit = getRateLimit(undefined, ipAddress);
    if (ipLimit && ipLimit.requestCount >= config.maxRequestsPerIpPerDay) {
      const hoursLeft = Math.ceil((24 * 60 * 60 * 1000 - (Date.now() - ipLimit.lastRequestTime)) / (60 * 60 * 1000));
      return {
        allowed: false,
        reason: `Rate limit exceeded for IP address. Try again in ${hoursLeft} hours.`,
      };
    }
  }

  return { allowed: true };
}

/**
 * Update rate limit counters
 */
function incrementRateLimit(walletAddress: string, ipAddress?: string): void {
  // Update wallet rate limit
  const walletLimit = getRateLimit(walletAddress);
  updateRateLimit({
    walletAddress,
    lastRequestTime: Date.now(),
    requestCount: walletLimit ? walletLimit.requestCount + 1 : 1,
  });

  // Update IP rate limit
  if (ipAddress) {
    const ipLimit = getRateLimit(undefined, ipAddress);
    updateRateLimit({
      ipAddress,
      lastRequestTime: Date.now(),
      requestCount: ipLimit ? ipLimit.requestCount + 1 : 1,
    });
  }
}

// Routes

/**
 * GET /health - Health check
 */
app.get('/health', async (req: Request, res: Response) => {
  try {
    const balance = await distributor.getMasterBalance();
    res.json({
      status: 'ok',
      masterWallet: (await distributor['account']).address,
      balance: balance.toString(),
    });
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /status - Get distributor status
 */
app.get('/status', async (req: Request, res: Response) => {
  try {
    const balance = await distributor.getMasterBalance();
    const gasPrice = await distributor.getGasPrice();

    res.json({
      masterWallet: (await distributor['account']).address,
      balance: balance.toString(),
      gasPrice: gasPrice.toString(),
      distributionAmount: config.distributionAmount,
      minBalance: config.minMasterBalance,
      threshold: config.minWalletBalanceThreshold,
    });
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /request - Request testnet ETH
 */
app.post('/request', async (req: Request, res: Response) => {
  try {
    const { walletAddress } = req.body;

    if (!walletAddress || !/^0x[a-fA-F0-9]{40}$/.test(walletAddress)) {
      return res.status(400).json({ error: 'Invalid wallet address' });
    }

    const ipAddress = req.ip || req.headers['x-forwarded-for'] as string;

    // Check rate limits
    const rateLimitCheck = checkRateLimit(walletAddress, ipAddress);
    if (!rateLimitCheck.allowed) {
      return res.status(429).json({ error: rateLimitCheck.reason });
    }

    // Check if there's already a pending request
    const existingRequest = getRequestByWallet(walletAddress);
    if (existingRequest && existingRequest.status === 'pending') {
      return res.status(409).json({
        error: 'You already have a pending request',
        request: existingRequest,
      });
    }

    // Check user balance
    const userBalance = await distributor.getUserBalance(walletAddress);
    const threshold = BigInt(config.minWalletBalanceThreshold) * BigInt(1e18);

    if (userBalance >= threshold) {
      return res.status(400).json({
        error: `Your wallet already has sufficient balance (${(Number(userBalance) / 1e18).toFixed(4)} ETH). Threshold: ${config.minWalletBalanceThreshold} ETH`,
      });
    }

    // Create request
    const request: FaucetRequest = {
      walletAddress: walletAddress.toLowerCase(),
      ipAddress,
      timestamp: Date.now(),
      status: 'approved', // Auto-approve for now
    };

    addRequest(request);
    incrementRateLimit(walletAddress, ipAddress);

    // Distribute ETH immediately (auto-approve)
    const result = await distributor.distributeETH(walletAddress);

    if (result.success) {
      updateRequest(walletAddress, {
        status: 'completed',
        txHash: result.txHash,
        amount: result.amount,
      });

      return res.json({
        success: true,
        message: 'ETH sent successfully!',
        txHash: result.txHash,
        amount: result.amount,
      });
    } else {
      updateRequest(walletAddress, {
        status: 'rejected',
      });

      return res.status(500).json({
        error: result.error || 'Distribution failed',
      });
    }

  } catch (error: any) {
    console.error('Request error:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /requests - Get all requests (admin)
 */
app.get('/requests', (req: Request, res: Response) => {
  const requests = loadRequests();
  res.json(requests);
});

/**
 * GET /requests/:address - Get request by wallet address
 */
app.get('/requests/:address', (req: Request, res: Response) => {
  const { address } = req.params;
  const request = getRequestByWallet(address);

  if (!request) {
    return res.status(404).json({ error: 'No request found for this address' });
  }

  res.json(request);
});

// Start server
export function startServer(): void {
  app.listen(config.port, () => {
    console.log(`\n🚀 Faucet Bot Server Running`);
    console.log(`================================`);
    console.log(`   Port: ${config.port}`);
    console.log(`   Endpoints:`);
    console.log(`   - GET  /health`);
    console.log(`   - GET  /status`);
    console.log(`   - POST /request`);
    console.log(`   - GET  /requests`);
    console.log(`   - GET  /requests/:address`);
    console.log(`================================\n`);

    // Print distributor status
    distributor.printStatus();
  });
}

// CLI execution
if (require.main === module) {
  startServer();
}
