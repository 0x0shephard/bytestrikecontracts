import { startServer } from './server';
import { FaucetClaimer } from './claim-faucet';
import { config } from './config';
import { getLastSuccessfulClaim } from './storage';

/**
 * Main bot entry point
 * Runs server and schedules periodic faucet claims
 */
async function main() {
  console.log('🤖 ByteStrike Faucet Bot Starting...');
  console.log('====================================\n');

  // Start API server
  startServer();

  // Check last claim time
  const lastClaim = getLastSuccessfulClaim();
  if (lastClaim) {
    const hoursSinceLastClaim = (Date.now() - lastClaim.timestamp) / (1000 * 60 * 60);
    console.log(`⏰ Last successful claim: ${new Date(lastClaim.timestamp).toLocaleString()}`);
    console.log(`   Time elapsed: ${hoursSinceLastClaim.toFixed(1)} hours`);

    if (hoursSinceLastClaim < config.claimIntervalHours) {
      const hoursUntilNext = config.claimIntervalHours - hoursSinceLastClaim;
      console.log(`   Next claim in: ${hoursUntilNext.toFixed(1)} hours\n`);
    } else {
      console.log(`   ✅ Ready to claim now!\n`);
    }
  } else {
    console.log(`⏰ No previous claims found. Ready to claim.\n`);
  }

  // Schedule periodic claims
  schedulePeriodicClaims();
}

/**
 * Schedule automatic faucet claims every 24 hours
 */
function schedulePeriodicClaims() {
  const intervalMs = config.claimIntervalHours * 60 * 60 * 1000;

  console.log(`📅 Scheduling automatic claims every ${config.claimIntervalHours} hours\n`);

  setInterval(async () => {
    console.log('\n⏰ Time to claim from faucet!');

    // Check if enough time has passed since last claim
    const lastClaim = getLastSuccessfulClaim();
    if (lastClaim) {
      const hoursSinceLastClaim = (Date.now() - lastClaim.timestamp) / (1000 * 60 * 60);
      if (hoursSinceLastClaim < config.claimIntervalHours - 0.5) {
        console.log(`⚠️  Too soon since last claim (${hoursSinceLastClaim.toFixed(1)}h ago). Skipping.`);
        return;
      }
    }

    try {
      const claimer = new FaucetClaimer();
      const result = await claimer.run();

      if (result.success) {
        console.log(`✅ Automatic claim successful! Amount: ${result.amount} ETH`);
        if (result.txHash) {
          console.log(`   Transaction: https://sepolia.etherscan.io/tx/${result.txHash}`);
        }
      } else {
        console.error(`❌ Automatic claim failed: ${result.error}`);
      }
    } catch (error: any) {
      console.error(`❌ Claim error:`, error.message);
    }
  }, intervalMs);

  // Optionally trigger immediate claim if last claim was long ago
  setTimeout(async () => {
    const lastClaim = getLastSuccessfulClaim();
    if (!lastClaim || (Date.now() - lastClaim.timestamp) > intervalMs) {
      console.log('\n🔄 Triggering initial faucet claim...');
      try {
        const claimer = new FaucetClaimer();
        const result = await claimer.run();
        if (result.success) {
          console.log(`✅ Initial claim successful! Amount: ${result.amount} ETH`);
        }
      } catch (error: any) {
        console.error(`❌ Initial claim failed:`, error.message);
      }
    }
  }, 5000); // Wait 5 seconds after startup
}

// Handle graceful shutdown
process.on('SIGINT', () => {
  console.log('\n\n👋 Shutting down gracefully...');
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('\n\n👋 Shutting down gracefully...');
  process.exit(0);
});

// Start the bot
main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
