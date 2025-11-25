import { chromium, Browser, Page } from 'playwright';
import { config, GOOGLE_FAUCET_URL } from './config';
import { FaucetClaim } from './types';
import { saveClaimHistory } from './storage';

/**
 * Automates claiming Sepolia ETH from Google Cloud faucet using Playwright
 */
export class FaucetClaimer {
  private browser: Browser | null = null;
  private page: Page | null = null;

  async initialize(): Promise<void> {
    console.log('🚀 Initializing browser for faucet claim...');
    this.browser = await chromium.launch({
      headless: config.headless,
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
    });

    const context = await this.browser.newContext({
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    });

    this.page = await context.newPage();
  }

  async loginToGoogle(): Promise<boolean> {
    if (!this.page) throw new Error('Browser not initialized');

    console.log('🔐 Logging into Google account...');

    try {
      // Navigate to Google sign-in
      await this.page.goto('https://accounts.google.com/signin', { waitUntil: 'networkidle' });

      // Enter email
      await this.page.fill('input[type="email"]', config.googleEmail);
      await this.page.click('button:has-text("Next")');
      await this.page.waitForTimeout(2000);

      // Enter password
      await this.page.fill('input[type="password"]', config.googlePassword);
      await this.page.click('button:has-text("Next")');
      await this.page.waitForTimeout(3000);

      console.log('✅ Google login successful');
      return true;
    } catch (error) {
      console.error('❌ Google login failed:', error);
      return false;
    }
  }

  async claimFromFaucet(): Promise<FaucetClaim> {
    if (!this.page) throw new Error('Browser not initialized');

    const claim: FaucetClaim = {
      timestamp: Date.now(),
      amount: '0.05',
      success: false,
    };

    try {
      console.log(`🌊 Navigating to Google Cloud Sepolia faucet...`);
      await this.page.goto(GOOGLE_FAUCET_URL, { waitUntil: 'networkidle', timeout: 60000 });

      // Wait for page to fully load
      await this.page.waitForTimeout(3000);

      // Look for wallet address input field (adjust selector based on actual page)
      console.log('📝 Filling wallet address...');
      const inputSelector = 'input[type="text"], input[placeholder*="address"], input[name*="address"]';
      await this.page.waitForSelector(inputSelector, { timeout: 10000 });
      await this.page.fill(inputSelector, config.faucetWalletAddress);

      // Look for send/claim button
      console.log('🖱️  Clicking claim button...');
      const buttonSelectors = [
        'button:has-text("Send")',
        'button:has-text("Claim")',
        'button:has-text("Request")',
        'button[type="submit"]',
      ];

      let buttonClicked = false;
      for (const selector of buttonSelectors) {
        try {
          await this.page.click(selector, { timeout: 5000 });
          buttonClicked = true;
          break;
        } catch (e) {
          continue;
        }
      }

      if (!buttonClicked) {
        throw new Error('Could not find claim button');
      }

      // Wait for response
      console.log('⏳ Waiting for transaction confirmation...');
      await this.page.waitForTimeout(5000);

      // Check for success message
      const successSelectors = [
        'text=/success/i',
        'text=/sent/i',
        'text=/claimed/i',
        'text=/transaction/i',
      ];

      let successFound = false;
      for (const selector of successSelectors) {
        try {
          await this.page.waitForSelector(selector, { timeout: 5000 });
          successFound = true;
          break;
        } catch (e) {
          continue;
        }
      }

      if (successFound) {
        console.log('✅ Faucet claim successful!');
        claim.success = true;

        // Try to extract transaction hash if visible
        try {
          const pageContent = await this.page.content();
          const txHashMatch = pageContent.match(/0x[a-fA-F0-9]{64}/);
          if (txHashMatch) {
            claim.txHash = txHashMatch[0];
            console.log(`📜 Transaction hash: ${claim.txHash}`);
          }
        } catch (e) {
          console.log('⚠️  Could not extract transaction hash');
        }
      } else {
        console.log('⚠️  Could not confirm claim success');
        claim.error = 'Success confirmation not found';
      }

      // Take screenshot for debugging
      await this.page.screenshot({ path: `./data/screenshots/claim-${Date.now()}.png` });

    } catch (error: any) {
      console.error('❌ Faucet claim failed:', error.message);
      claim.success = false;
      claim.error = error.message;

      // Take screenshot on error
      try {
        await this.page?.screenshot({ path: `./data/screenshots/error-${Date.now()}.png` });
      } catch (e) {
        // Ignore screenshot errors
      }
    }

    // Save claim history
    await saveClaimHistory(claim);

    return claim;
  }

  async close(): Promise<void> {
    console.log('🔒 Closing browser...');
    if (this.browser) {
      await this.browser.close();
      this.browser = null;
      this.page = null;
    }
  }

  async run(): Promise<FaucetClaim> {
    try {
      await this.initialize();

      // Login to Google (only needed first time or if session expired)
      const loginSuccess = await this.loginToGoogle();
      if (!loginSuccess) {
        throw new Error('Google login failed');
      }

      // Claim from faucet
      const claim = await this.claimFromFaucet();

      return claim;
    } finally {
      await this.close();
    }
  }
}

// CLI execution
if (require.main === module) {
  (async () => {
    console.log('🤖 ByteStrike Faucet Bot - Manual Claim');
    console.log('=====================================\n');

    const claimer = new FaucetClaimer();
    const result = await claimer.run();

    console.log('\n📊 Claim Result:');
    console.log(JSON.stringify(result, null, 2));

    process.exit(result.success ? 0 : 1);
  })();
}
