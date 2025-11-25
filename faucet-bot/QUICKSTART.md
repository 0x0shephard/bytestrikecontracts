# Quick Start Guide 🚀

Get the ByteStrike Faucet Bot running in 5 minutes!

## Step 1: Install Dependencies (2 min)

```bash
cd faucet-bot
npm install
npx playwright install chromium
```

## Step 2: Configure Environment (1 min)

```bash
cp .env.example .env
```

Edit `.env` with **minimum required** values:

```bash
# Required: Your Sepolia RPC (get free from Alchemy)
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Required: Private key of wallet to distribute from
MASTER_WALLET_PRIVATE_KEY=0xYOUR_PRIVATE_KEY

# Required: Google account for faucet
GOOGLE_EMAIL=your-email@gmail.com
GOOGLE_PASSWORD=your-password

# Required: Same as master wallet address
FAUCET_WALLET_ADDRESS=0xYourMasterWalletAddress
```

⚠️ **Security**: Use a dedicated testnet wallet, not your main wallet!

## Step 3: Build (30 sec)

```bash
npm run build
```

## Step 4: Test Manual Claim (1 min)

Test the faucet claim with visible browser:

```bash
# Set headless to false in .env first
HEADLESS=false npm run claim
```

Watch the browser:
1. Login to Google
2. Navigate to faucet
3. Fill wallet address
4. Click claim button

Check result in terminal.

## Step 5: Start the Bot (30 sec)

```bash
npm start
```

You should see:
```
🚀 Faucet Bot Server Running
================================
   Port: 3001
   ...
================================

📊 ETH Distributor Status
========================
Master Wallet: 0x...
Balance: X.XXXX ETH
...
```

## Step 6: Test API (30 sec)

### Test health check:
```bash
curl http://localhost:3001/health
```

### Test distribution request:
```bash
curl -X POST http://localhost:3001/request \
  -H "Content-Type: application/json" \
  -d '{"walletAddress":"0xYourTestWalletAddress"}'
```

## Step 7: Integrate Frontend (1 min)

### Add to your trading page:

```jsx
// In newbs/src/tradingpage.jsx or similar
import { FaucetRequest } from './components/FaucetRequest';

export default function TradingPage() {
  return (
    <div>
      {/* Your existing components */}

      {/* Add faucet component */}
      <FaucetRequest />
    </div>
  );
}
```

### Add environment variable:

In `newbs/.env`:
```bash
VITE_FAUCET_API_URL=http://localhost:3001
```

### Start frontend:
```bash
cd ../newbs
npm run dev
```

## Done! ✅

Your faucet bot is now:
- ✅ Claiming from Google Cloud faucet every 24h
- ✅ Serving API on port 3001
- ✅ Ready to distribute to users via frontend

## Quick Test Checklist

- [ ] Bot server running without errors
- [ ] Master wallet has testnet ETH
- [ ] Can access http://localhost:3001/health
- [ ] Frontend can connect to API
- [ ] Can request ETH through frontend
- [ ] Transaction appears on Sepolia Etherscan

## Common Issues

### "Cannot find module 'playwright'"
```bash
npm install
npx playwright install chromium
```

### "Google login failed"
- Check credentials in `.env`
- Try with `HEADLESS=false` to see what's happening
- May need app-specific password if 2FA enabled

### "Insufficient master balance"
Fund your master wallet:
```bash
# Get testnet ETH from public faucets first:
# - https://faucets.chain.link/sepolia
# - https://www.alchemy.com/faucets/ethereum-sepolia
```

### "Rate limit exceeded"
Clear rate limits (for testing):
```bash
echo "[]" > data/rate-limits.json
```

### Frontend can't connect to API
Check CORS and API URL:
1. Ensure `VITE_FAUCET_API_URL=http://localhost:3001` in `newbs/.env`
2. Restart frontend: `npm run dev`

## Next Steps

- 📖 Read full [README.md](README.md) for advanced configuration
- 🚀 Deploy to production (PM2, Docker, VPS)
- 🔒 Add monitoring and alerts
- 🎨 Customize frontend component styling

## Support

- Check `data/screenshots/` for browser automation issues
- Review server logs for API errors
- Test endpoints with `curl` to isolate issues

---

**Happy Testing! 🎉**
