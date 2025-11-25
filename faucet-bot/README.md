# ByteStrike Faucet Bot 🤖💧

Automated Sepolia testnet ETH distribution bot that claims from Google Cloud faucet every 24 hours and distributes to users through a web interface.

## Features

✅ **Automated Faucet Claims**: Claims 0.05 ETH from Google Cloud Sepolia faucet every 24 hours using Playwright browser automation

✅ **Smart Distribution**: Distributes 0.04 ETH to users who request through the frontend

✅ **Rate Limiting**: Prevents abuse with wallet-based (1 request/24h) and IP-based (3 requests/24h) rate limiting

✅ **Balance Checks**: Only distributes if user has less than 0.05 ETH

✅ **REST API**: Express server with CORS support for frontend integration

✅ **Request Tracking**: JSON-based storage for tracking all requests and claims

✅ **TypeScript**: Fully typed with Viem for blockchain interactions

## Architecture

```
┌─────────────────────────────────────────────────────┐
│              Google Cloud Faucet                    │
│   https://cloud.google.com/.../sepolia             │
│              (0.05 ETH/24h)                         │
└──────────────────┬──────────────────────────────────┘
                   │
                   │ Playwright Browser Automation
                   │ (Every 24 hours)
                   ▼
┌─────────────────────────────────────────────────────┐
│           Master Wallet (Bot Wallet)                │
│          Accumulates Testnet ETH                    │
└──────────────────┬──────────────────────────────────┘
                   │
                   │ Viem Direct Transfer
                   │ (0.04 ETH per request)
                   ▼
┌─────────────────────────────────────────────────────┐
│              User Wallets                           │
│         (Via Frontend Request)                      │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│               Backend Services                      │
│                                                     │
│  ┌───────────────┐  ┌──────────────┐              │
│  │ Faucet Claimer│  │ ETH Distributor│             │
│  │  (Playwright) │  │     (Viem)    │             │
│  └───────┬───────┘  └───────┬──────┘              │
│          │                   │                      │
│          └───────┬───────────┘                      │
│                  │                                  │
│          ┌───────▼────────┐                        │
│          │  Express API   │                        │
│          │   (Port 3001)  │                        │
│          └───────┬────────┘                        │
│                  │                                  │
│          ┌───────▼────────┐                        │
│          │ JSON Storage   │                        │
│          │ - requests.json│                        │
│          │ - claims.json  │                        │
│          │ - rate-limits  │                        │
│          └────────────────┘                        │
└─────────────────────────────────────────────────────┘
                   ▲
                   │ HTTP REST API
                   │
┌──────────────────┴──────────────────────────────────┐
│             Frontend (React)                        │
│                                                     │
│  ┌──────────────────────────────────┐              │
│  │    FaucetRequest Component       │              │
│  │  - Balance display               │              │
│  │  - Request button                │              │
│  │  - Status tracking               │              │
│  │  - Transaction links             │              │
│  └──────────────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

## Installation

### Prerequisites

- Node.js 18+ and npm/yarn
- A Google account (for faucet access)
- A funded Sepolia wallet (master wallet for distribution)
- Sepolia RPC URL (Alchemy recommended)

### 1. Install Dependencies

```bash
cd faucet-bot
npm install
```

### 2. Install Playwright Browsers

```bash
npx playwright install chromium
```

### 3. Configure Environment

```bash
cp .env.example .env
```

Edit `.env` with your configuration:

```bash
# Blockchain Configuration
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
MASTER_WALLET_PRIVATE_KEY=0xYOUR_PRIVATE_KEY_HERE

# Google Cloud Faucet Configuration
GOOGLE_EMAIL=your-email@gmail.com
GOOGLE_PASSWORD=your-google-password
FAUCET_WALLET_ADDRESS=0xYourMasterWalletAddress

# Bot Configuration
PORT=3001
CLAIM_INTERVAL_HOURS=24
DISTRIBUTION_AMOUNT=0.04
MIN_MASTER_BALANCE=0.1

# Rate Limiting
MAX_REQUESTS_PER_WALLET_PER_DAY=1
MAX_REQUESTS_PER_IP_PER_DAY=3
MIN_WALLET_BALANCE_THRESHOLD=0.05

# Browser (set to false for debugging)
HEADLESS=true
```

### 4. Build

```bash
npm run build
```

## Usage

### Start the Bot (Full Service)

Runs the API server and schedules automatic faucet claims every 24 hours:

```bash
npm start
```

This will:
- Start Express API server on port 3001
- Schedule automatic faucet claims every 24 hours
- Handle incoming distribution requests from frontend

### Manual Faucet Claim

To manually claim from the faucet (for testing):

```bash
npm run claim
```

This will:
- Open a browser (or headless if configured)
- Login to Google
- Navigate to the faucet
- Claim testnet ETH
- Save claim history

### Development Mode

```bash
npm run dev
```

## API Endpoints

### `GET /health`

Health check endpoint.

**Response:**
```json
{
  "status": "ok",
  "masterWallet": "0x...",
  "balance": "1000000000000000000"
}
```

### `GET /status`

Get distributor status and configuration.

**Response:**
```json
{
  "masterWallet": "0x...",
  "balance": "1000000000000000000",
  "gasPrice": "20000000000",
  "distributionAmount": "0.04",
  "minBalance": "0.1",
  "threshold": "0.05"
}
```

### `POST /request`

Request testnet ETH distribution.

**Request Body:**
```json
{
  "walletAddress": "0x..."
}
```

**Success Response (200):**
```json
{
  "success": true,
  "message": "ETH sent successfully!",
  "txHash": "0x...",
  "amount": "0.04"
}
```

**Error Responses:**
- `400` - Invalid wallet address or sufficient balance
- `429` - Rate limit exceeded
- `409` - Pending request already exists
- `500` - Distribution failed

### `GET /requests`

Get all requests (admin endpoint).

**Response:**
```json
[
  {
    "walletAddress": "0x...",
    "ipAddress": "192.168.1.1",
    "timestamp": 1704067200000,
    "status": "completed",
    "txHash": "0x...",
    "amount": "0.04"
  }
]
```

### `GET /requests/:address`

Get request by wallet address.

**Response:**
```json
{
  "walletAddress": "0x...",
  "ipAddress": "192.168.1.1",
  "timestamp": 1704067200000,
  "status": "completed",
  "txHash": "0x...",
  "amount": "0.04"
}
```

## Frontend Integration

### 1. Add Environment Variable

In `newbs/.env`:

```bash
VITE_FAUCET_API_URL=http://localhost:3001
```

For production:
```bash
VITE_FAUCET_API_URL=https://your-faucet-api.com
```

### 2. Import Component

```jsx
import { FaucetRequest } from './components/FaucetRequest';

function TradingPage() {
  return (
    <div>
      {/* Your existing components */}
      <FaucetRequest />
    </div>
  );
}
```

### 3. Component Features

- **Balance Display**: Shows current wallet balance
- **Smart Button**: Disabled if balance > 0.05 ETH
- **Status Tracking**: Shows last request status
- **Transaction Links**: Direct links to Etherscan
- **Toast Notifications**: Real-time feedback
- **Loading States**: Spinner during requests

## Data Storage

All data is stored in JSON files in the `data/` directory:

### `data/requests.json`

```json
[
  {
    "walletAddress": "0x123...",
    "ipAddress": "192.168.1.1",
    "timestamp": 1704067200000,
    "status": "completed",
    "txHash": "0xabc...",
    "amount": "0.04"
  }
]
```

### `data/claims.json`

```json
[
  {
    "timestamp": 1704067200000,
    "amount": "0.05",
    "txHash": "0xdef...",
    "success": true
  }
]
```

### `data/rate-limits.json`

```json
[
  {
    "walletAddress": "0x123...",
    "lastRequestTime": 1704067200000,
    "requestCount": 1
  }
]
```

### `data/screenshots/`

Browser screenshots for debugging (claim and error screenshots).

## Configuration Options

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3001` | API server port |
| `CLAIM_INTERVAL_HOURS` | `24` | Hours between faucet claims |
| `DISTRIBUTION_AMOUNT` | `0.04` | ETH to send per request |
| `MIN_MASTER_BALANCE` | `0.1` | Minimum balance to keep in master wallet |
| `MAX_REQUESTS_PER_WALLET_PER_DAY` | `1` | Max requests per wallet per 24h |
| `MAX_REQUESTS_PER_IP_PER_DAY` | `3` | Max requests per IP per 24h |
| `MIN_WALLET_BALANCE_THRESHOLD` | `0.05` | Only send if user has less than this |
| `HEADLESS` | `true` | Run browser in headless mode |

## Security Considerations

⚠️ **Important Security Notes:**

1. **Private Key Storage**: Never commit `.env` to git. Use environment variables in production.

2. **Google Credentials**: Store securely. Consider using OAuth instead of password for production.

3. **Rate Limiting**: The bot implements rate limiting, but consider adding additional layers (e.g., CAPTCHA, email verification).

4. **Master Wallet**: Keep minimal balance in master wallet. Refill as needed.

5. **API Access**: In production, add authentication to admin endpoints (`/requests`).

6. **CORS**: Configure CORS properly for production (restrict origins).

## Troubleshooting

### Browser automation fails

**Solution**: Run with `HEADLESS=false` to see what's happening:

```bash
HEADLESS=false npm run claim
```

Check screenshots in `data/screenshots/` for errors.

### Google login fails

**Solutions**:
- Enable "Less secure app access" in Google account settings
- Use an app-specific password
- Consider implementing OAuth flow instead

### Rate limit errors

Check rate limit data:
```bash
cat data/rate-limits.json
```

Manually clear if needed (for testing):
```bash
echo "[]" > data/rate-limits.json
```

### Distribution fails

Check master wallet balance:
```bash
curl http://localhost:3001/status
```

Ensure master wallet has sufficient ETH.

## Production Deployment

### Option 1: VPS (Recommended)

1. Deploy to VPS (DigitalOcean, AWS, etc.)
2. Use PM2 for process management:
   ```bash
   npm install -g pm2
   pm2 start dist/index.js --name faucet-bot
   pm2 save
   pm2 startup
   ```

3. Set up reverse proxy with Nginx
4. Use SSL certificate (Let's Encrypt)

### Option 2: Docker

```dockerfile
FROM node:18-alpine

WORKDIR /app

# Install Playwright dependencies
RUN apk add --no-cache \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

EXPOSE 3001

CMD ["npm", "start"]
```

Build and run:
```bash
docker build -t faucet-bot .
docker run -d --env-file .env -p 3001:3001 faucet-bot
```

### Option 3: Serverless (Limited)

⚠️ **Not recommended** due to Playwright requirements and long-running processes.

## Monitoring

Add monitoring to track:
- Successful/failed claims
- Distribution success rate
- Master wallet balance
- API uptime
- Error rates

Consider integrating:
- SendGrid for email alerts
- Sentry for error tracking
- Prometheus/Grafana for metrics

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

MIT License

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review screenshots in `data/screenshots/`
3. Check server logs
4. Open an issue on GitHub

---

**Made with ❤️ for ByteStrike Testnet Users**
