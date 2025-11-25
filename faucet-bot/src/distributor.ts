import { createPublicClient, createWalletClient, http, parseEther, formatEther, Account, Chain } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import { config } from './config';
import { DistributionResult } from './types';

/**
 * Handles ETH distribution from master wallet to users
 */
export class ETHDistributor {
  private account: Account;
  private publicClient: ReturnType<typeof createPublicClient>;
  private walletClient: ReturnType<typeof createWalletClient>;

  constructor() {
    // Create account from private key
    this.account = privateKeyToAccount(config.masterWalletPrivateKey as `0x${string}`);

    // Create clients
    this.publicClient = createPublicClient({
      chain: sepolia as Chain,
      transport: http(config.sepoliaRpcUrl),
    });

    this.walletClient = createWalletClient({
      account: this.account,
      chain: sepolia as Chain,
      transport: http(config.sepoliaRpcUrl),
    });

    console.log(`💼 ETH Distributor initialized`);
    console.log(`   Master Wallet: ${this.account.address}`);
  }

  async getMasterBalance(): Promise<bigint> {
    const balance = await this.publicClient.getBalance({
      address: this.account.address,
    });
    return balance;
  }

  async getUserBalance(userAddress: string): Promise<bigint> {
    const balance = await this.publicClient.getBalance({
      address: userAddress as `0x${string}`,
    });
    return balance;
  }

  async checkCanDistribute(userAddress: string): Promise<{ canDistribute: boolean; reason?: string }> {
    // Check master wallet balance
    const masterBalance = await this.getMasterBalance();
    const minBalance = parseEther(config.minMasterBalance);
    const distributionAmount = parseEther(config.distributionAmount);

    if (masterBalance < minBalance + distributionAmount) {
      return {
        canDistribute: false,
        reason: `Insufficient master balance. Current: ${formatEther(masterBalance)} ETH, Need: ${formatEther(minBalance + distributionAmount)} ETH`,
      };
    }

    // Check user balance (only send if user has less than threshold)
    const userBalance = await this.getUserBalance(userAddress);
    const threshold = parseEther(config.minWalletBalanceThreshold);

    if (userBalance >= threshold) {
      return {
        canDistribute: false,
        reason: `User already has sufficient balance: ${formatEther(userBalance)} ETH (threshold: ${formatEther(threshold)} ETH)`,
      };
    }

    return { canDistribute: true };
  }

  async distributeETH(toAddress: string): Promise<DistributionResult> {
    const result: DistributionResult = {
      success: false,
    };

    try {
      console.log(`\n💸 Distributing ETH to ${toAddress}...`);

      // Pre-flight checks
      const check = await this.checkCanDistribute(toAddress);
      if (!check.canDistribute) {
        result.error = check.reason;
        console.log(`❌ ${check.reason}`);
        return result;
      }

      const amount = parseEther(config.distributionAmount);
      result.amount = config.distributionAmount;

      // Get current balances
      const masterBalance = await this.getMasterBalance();
      const userBalanceBefore = await this.getUserBalance(toAddress);

      console.log(`   Master Balance: ${formatEther(masterBalance)} ETH`);
      console.log(`   User Balance Before: ${formatEther(userBalanceBefore)} ETH`);
      console.log(`   Sending Amount: ${config.distributionAmount} ETH`);

      // Send transaction
      const hash = await this.walletClient.sendTransaction({
        to: toAddress as `0x${string}`,
        value: amount,
      });

      console.log(`   Transaction Hash: ${hash}`);
      console.log(`   Waiting for confirmation...`);

      // Wait for transaction receipt
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash,
        confirmations: 1,
      });

      if (receipt.status === 'success') {
        const userBalanceAfter = await this.getUserBalance(toAddress);
        console.log(`   User Balance After: ${formatEther(userBalanceAfter)} ETH`);
        console.log(`✅ Distribution successful!`);

        result.success = true;
        result.txHash = hash;
      } else {
        result.error = 'Transaction reverted';
        console.log(`❌ Transaction reverted`);
      }

    } catch (error: any) {
      result.error = error.message || 'Unknown error';
      console.error(`❌ Distribution failed:`, error.message);
    }

    return result;
  }

  async estimateGas(toAddress: string): Promise<bigint> {
    const gas = await this.publicClient.estimateGas({
      account: this.account,
      to: toAddress as `0x${string}`,
      value: parseEther(config.distributionAmount),
    });
    return gas;
  }

  async getGasPrice(): Promise<bigint> {
    const gasPrice = await this.publicClient.getGasPrice();
    return gasPrice;
  }

  async printStatus(): Promise<void> {
    console.log('\n📊 ETH Distributor Status');
    console.log('========================');

    const balance = await this.getMasterBalance();
    const gasPrice = await this.getGasPrice();

    console.log(`Master Wallet: ${this.account.address}`);
    console.log(`Balance: ${formatEther(balance)} ETH`);
    console.log(`Gas Price: ${formatEther(gasPrice)} ETH`);
    console.log(`Distribution Amount: ${config.distributionAmount} ETH`);
    console.log(`Min Master Balance: ${config.minMasterBalance} ETH`);
    console.log(`User Balance Threshold: ${config.minWalletBalanceThreshold} ETH`);

    const distributionAmount = parseEther(config.distributionAmount);
    const minBalance = parseEther(config.minMasterBalance);
    const availableForDistribution = balance > minBalance ? balance - minBalance : 0n;
    const maxDistributions = availableForDistribution / distributionAmount;

    console.log(`\nMax Distributions Available: ${maxDistributions}`);
    console.log('========================\n');
  }
}
