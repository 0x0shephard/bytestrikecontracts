# Deployment Guide 🚀

Complete deployment guide for ByteStrike Faucet Bot on multiple platforms.

## Overview

Choose your deployment platform based on your needs:

| Platform | Cost | Difficulty | Best For |
|----------|------|------------|----------|
| **Railway** | $5/mo | ⭐ Easy | Quickest deployment |
| **Render** | Free-$7/mo | ⭐⭐ Easy | Free tier testing |
| **Fly.io** | $3-5/mo | ⭐⭐⭐ Medium | Global deployment |
| **Docker** | Variable | ⭐⭐⭐ Medium | Self-hosting |

---

## 🚂 Option 1: Railway.app (Recommended)

**Cost**: $5/month | **Difficulty**: ⭐ Easy | **Time**: 10 minutes

### Why Railway?
- ✅ Easiest deployment
- ✅ Automatic HTTPS
- ✅ Built-in monitoring
- ✅ GitHub auto-deploy
- ✅ Persistent storage

### Prerequisites
- GitHub account
- Railway account (free to create)
- Your environment variables ready

### Step-by-Step Deployment

#### 1. Push Code to GitHub

```bash
# Initialize git (if not already)
cd byte-strike
git add faucet-bot/
git commit -m "Add faucet bot"
git push origin main
```

#### 2. Create Railway Project

1. Go to [railway.app](https://railway.app)
2. Click **"Start a New Project"**
3. Select **"Deploy from GitHub repo"**
4. Authorize Railway to access your GitHub
5. Select your `byte-strike` repository

#### 3. Configure Build Settings

Railway will auto-detect Node.js. Verify settings:

- **Root Directory**: `faucet-bot`
- **Build Command**: `npm install && npx playwright install chromium --with-deps && npm run build`
- **Start Command**: `npm start`

#### 4. Add Environment Variables

In Railway dashboard, go to **Variables** tab and add:

```bash
# Blockchain
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
MASTER_WALLET_PRIVATE_KEY=0xYOUR_PRIVATE_KEY

# Google Faucet
GOOGLE_EMAIL=your-email@gmail.com
GOOGLE_PASSWORD=your-password
FAUCET_WALLET_ADDRESS=0xYourMasterWalletAddress

# Bot Config
PORT=3001
CLAIM_INTERVAL_HOURS=24
DISTRIBUTION_AMOUNT=0.04
MIN_MASTER_BALANCE=0.1
MAX_REQUESTS_PER_WALLET_PER_DAY=1
MAX_REQUESTS_PER_IP_PER_DAY=3
MIN_WALLET_BALANCE_THRESHOLD=0.05
HEADLESS=true
```

#### 5. Deploy

1. Click **"Deploy"**
2. Wait 3-5 minutes for build
3. Railway will show deployment logs

#### 6. Get Your Public URL

1. Go to **Settings** tab
2. Under **Networking**, click **"Generate Domain"**
3. You'll get a URL like: `https://bytestrike-faucet-bot.up.railway.app`

#### 7. Test Deployment

```bash
# Replace with your Railway URL
curl https://your-app.up.railway.app/health
```

#### 8. Update Frontend

In `newbs/.env`:
```bash
VITE_FAUCET_API_URL=https://your-app.up.railway.app
```

#### 9. Add Persistent Storage (Important!)

1. In Railway dashboard, go to **Data** tab
2. Click **"New Volume"**
3. Mount path: `/app/faucet-bot/data`
4. Size: 1 GB
5. Click **"Add"**

### Monitoring & Logs

- **View Logs**: Railway dashboard → **Deployments** → **View Logs**
- **Metrics**: Dashboard shows CPU, memory, network usage
- **Restart**: Settings → **Restart**

### Auto-Deploy

Railway automatically redeploys when you push to GitHub:

```bash
git commit -m "Update faucet bot"
git push origin main
# Railway detects and redeploys automatically
```

---

## 🎨 Option 2: Render.com

**Cost**: Free (limited) or $7/month | **Difficulty**: ⭐⭐ Easy | **Time**: 15 minutes

### Why Render?
- ✅ Free tier available
- ✅ Easy setup
- ✅ Persistent disks
- ✅ Auto-deploy from Git

### Limitations
- ⚠️ Free tier spins down after 15 min inactivity (not ideal for faucet bot)
- ⚠️ Use **Starter** plan ($7/mo) for always-on service

### Step-by-Step Deployment

#### 1. Push Code to GitHub

```bash
cd byte-strike
git add faucet-bot/
git commit -m "Add faucet bot"
git push origin main
```

#### 2. Create Render Account

1. Go to [render.com](https://render.com)
2. Sign up with GitHub
3. Click **"New +"** → **"Web Service"**

#### 3. Connect Repository

1. Select **"Build and deploy from a Git repository"**
2. Connect your GitHub account
3. Select `byte-strike` repository
4. Choose branch: `main`

#### 4. Configure Service

**Basic Settings:**
- **Name**: `bytestrike-faucet-bot`
- **Region**: Choose closest to your users
- **Branch**: `main`
- **Root Directory**: `faucet-bot`

**Build Settings:**
- **Runtime**: `Node`
- **Build Command**: `npm install && npx playwright install chromium --with-deps && npm run build`
- **Start Command**: `npm start`

**Plan:**
- Choose **Starter ($7/month)** for always-on
- Or **Free** for testing (spins down after 15 min)

#### 5. Add Environment Variables

Click **"Advanced"** → **"Add Environment Variable"**

Add all variables from `.env.example`:

```bash
SEPOLIA_RPC_URL=...
MASTER_WALLET_PRIVATE_KEY=...
GOOGLE_EMAIL=...
GOOGLE_PASSWORD=...
FAUCET_WALLET_ADDRESS=...
PORT=3001
CLAIM_INTERVAL_HOURS=24
DISTRIBUTION_AMOUNT=0.04
MIN_MASTER_BALANCE=0.1
MAX_REQUESTS_PER_WALLET_PER_DAY=1
MAX_REQUESTS_PER_IP_PER_DAY=3
MIN_WALLET_BALANCE_THRESHOLD=0.05
HEADLESS=true
```

#### 6. Add Persistent Disk

1. Scroll to **"Disk"**
2. Click **"Add Disk"**
3. **Name**: `faucet-data`
4. **Mount Path**: `/app/faucet-bot/data`
5. **Size**: 1 GB

#### 7. Create Web Service

1. Click **"Create Web Service"**
2. Wait 5-10 minutes for deployment
3. Watch build logs

#### 8. Get Your URL

Render provides a URL like: `https://bytestrike-faucet-bot.onrender.com`

#### 9. Test Deployment

```bash
curl https://your-app.onrender.com/health
```

#### 10. Update Frontend

In `newbs/.env`:
```bash
VITE_FAUCET_API_URL=https://your-app.onrender.com
```

### Using render.yaml (Alternative)

Instead of manual setup, use the `render.yaml` file:

1. Push `render.yaml` to your repo
2. In Render dashboard, click **"New +"** → **"Blueprint"**
3. Connect repository
4. Render will auto-configure from YAML
5. Add secret environment variables in dashboard

---

## ✈️ Option 3: Fly.io

**Cost**: $3-5/month | **Difficulty**: ⭐⭐⭐ Medium | **Time**: 20 minutes

### Why Fly.io?
- ✅ Global deployment
- ✅ Docker-based (flexible)
- ✅ Good performance
- ✅ Persistent volumes

### Prerequisites
- Fly.io account
- Fly CLI installed
- Docker knowledge helpful

### Step-by-Step Deployment

#### 1. Install Fly CLI

**macOS:**
```bash
brew install flyctl
```

**Linux:**
```bash
curl -L https://fly.io/install.sh | sh
```

**Windows:**
```powershell
iwr https://fly.io/install.ps1 -useb | iex
```

#### 2. Login to Fly

```bash
fly auth login
```

#### 3. Initialize Fly App

```bash
cd faucet-bot
fly launch --no-deploy
```

Answer prompts:
- **App name**: `bytestrike-faucet-bot` (or auto-generate)
- **Region**: Choose closest to users
- **Postgres**: No
- **Redis**: No

This creates `fly.toml` (already provided in repo).

#### 4. Create Persistent Volume

```bash
fly volumes create faucet_data --size 1 --region sjc
```

Replace `sjc` with your chosen region.

#### 5. Set Environment Secrets

```bash
fly secrets set \
  SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY" \
  MASTER_WALLET_PRIVATE_KEY="0xYOUR_PRIVATE_KEY" \
  GOOGLE_EMAIL="your-email@gmail.com" \
  GOOGLE_PASSWORD="your-password" \
  FAUCET_WALLET_ADDRESS="0xYourMasterWalletAddress" \
  CLAIM_INTERVAL_HOURS="24" \
  DISTRIBUTION_AMOUNT="0.04" \
  MIN_MASTER_BALANCE="0.1" \
  MAX_REQUESTS_PER_WALLET_PER_DAY="1" \
  MAX_REQUESTS_PER_IP_PER_DAY="3" \
  MIN_WALLET_BALANCE_THRESHOLD="0.05"
```

#### 6. Deploy

```bash
fly deploy
```

This will:
- Build Docker image
- Push to Fly registry
- Deploy to your region
- Start the app

#### 7. Get Your URL

```bash
fly info
```

Your URL: `https://bytestrike-faucet-bot.fly.dev`

#### 8. Test Deployment

```bash
curl https://bytestrike-faucet-bot.fly.dev/health
```

#### 9. View Logs

```bash
fly logs
```

#### 10. Scale (Optional)

```bash
# Scale to 512MB RAM, 1 CPU
fly scale vm shared-cpu-1x --memory 512

# Scale to multiple regions
fly regions add lax dfw
```

### Useful Fly Commands

```bash
# SSH into machine
fly ssh console

# View metrics
fly status

# Scale instances
fly scale count 2

# Open app in browser
fly open

# Check health
fly checks list
```

---

## 🐳 Option 4: Docker (Self-Hosting)

**Cost**: Variable (your infrastructure) | **Difficulty**: ⭐⭐⭐ Medium

### Why Docker?
- ✅ Run anywhere (VPS, home server, cloud)
- ✅ Consistent environment
- ✅ Easy scaling
- ✅ Full control

### Prerequisites
- Docker installed
- Docker Compose (optional)

### Step-by-Step Deployment

#### 1. Build Docker Image

```bash
cd faucet-bot
docker build -t bytestrike-faucet-bot .
```

#### 2. Create .env File

```bash
cp .env.example .env
# Edit .env with your values
nano .env
```

#### 3. Run Container

**Basic Run:**
```bash
docker run -d \
  --name faucet-bot \
  --env-file .env \
  -p 3001:3001 \
  -v $(pwd)/data:/app/faucet-bot/data \
  --restart unless-stopped \
  bytestrike-faucet-bot
```

**Docker Compose (Recommended):**

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  faucet-bot:
    build: .
    container_name: bytestrike-faucet-bot
    restart: unless-stopped
    ports:
      - "3001:3001"
    env_file:
      - .env
    volumes:
      - ./data:/app/faucet-bot/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

Then run:

```bash
docker-compose up -d
```

#### 4. View Logs

```bash
# Docker
docker logs -f faucet-bot

# Docker Compose
docker-compose logs -f
```

#### 5. Test

```bash
curl http://localhost:3001/health
```

#### 6. Expose to Internet (VPS)

**Using Nginx:**

```nginx
# /etc/nginx/sites-available/faucet-bot
server {
    listen 80;
    server_name faucet.yourdomain.com;

    location / {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Enable and restart:

```bash
sudo ln -s /etc/nginx/sites-available/faucet-bot /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

**Add SSL with Certbot:**

```bash
sudo certbot --nginx -d faucet.yourdomain.com
```

---

## 🔍 Post-Deployment Checklist

After deploying to any platform:

### 1. Verify Health Endpoint
```bash
curl https://your-app-url.com/health
```

Expected response:
```json
{
  "status": "ok",
  "masterWallet": "0x...",
  "balance": "..."
}
```

### 2. Test Distribution
```bash
curl -X POST https://your-app-url.com/request \
  -H "Content-Type: application/json" \
  -d '{"walletAddress":"0xYourTestWallet"}'
```

### 3. Update Frontend

In `newbs/.env`:
```bash
VITE_FAUCET_API_URL=https://your-deployed-url.com
```

Rebuild frontend:
```bash
cd newbs
npm run build
```

### 4. Monitor First Claim

Wait for first automated claim (or trigger manually):
- Check logs for "🌊 Navigating to Google Cloud Sepolia faucet"
- Verify claim success in logs
- Check screenshots in `data/screenshots/`

### 5. Test Rate Limiting

Try requesting twice quickly:
```bash
# First request - should succeed
curl -X POST https://your-app-url.com/request \
  -H "Content-Type: application/json" \
  -d '{"walletAddress":"0x123..."}'

# Second request - should fail with rate limit error
curl -X POST https://your-app-url.com/request \
  -H "Content-Type: application/json" \
  -d '{"walletAddress":"0x123..."}'
```

### 6. Verify Persistent Storage

Restart the service and check if data persists:
- `data/requests.json` should still exist
- Rate limits should be remembered
- Claim history should be intact

---

## 🔧 Troubleshooting

### Common Issues

#### 1. Playwright/Chromium Errors

**Error**: `browserType.launch: Executable doesn't exist`

**Solution**:
```bash
# Ensure Playwright is installed with deps
npx playwright install chromium --with-deps
```

For Docker, ensure Chromium is in the image (already included in our Dockerfile).

#### 2. Google Login Fails

**Error**: Google blocks login attempt

**Solutions**:
- Use app-specific password (if 2FA enabled)
- Enable "Less secure app access" (not recommended)
- Set `HEADLESS=false` to debug visually
- Check screenshots in `data/screenshots/`

#### 3. Master Wallet Low Balance

**Error**: `Insufficient master balance`

**Solution**:
```bash
# Get testnet ETH from public faucets:
# - https://faucets.chain.link/sepolia
# - https://www.alchemy.com/faucets/ethereum-sepolia
# Send to your master wallet address
```

#### 4. Port Already in Use

**Error**: `EADDRINUSE: address already in use :::3001`

**Solution**:
```bash
# Change PORT in environment variables
PORT=3002

# Or kill existing process
lsof -ti:3001 | xargs kill
```

#### 5. CORS Errors on Frontend

**Error**: `blocked by CORS policy`

**Solution**: Update `src/server.ts`:
```typescript
app.use(cors({
  origin: ['https://your-frontend-domain.com', 'http://localhost:5173'],
  credentials: true
}));
```

#### 6. Rate Limit Data Not Persisting

**Issue**: Users can request multiple times

**Solution**: Ensure persistent volume is mounted:
- Railway: Add volume in dashboard
- Render: Add disk with correct mount path
- Fly: Create and mount volume
- Docker: Use `-v` flag for data directory

---

## 📊 Monitoring & Maintenance

### View Logs

**Railway:**
```
Dashboard → Deployments → View Logs
```

**Render:**
```
Dashboard → Logs tab (real-time)
```

**Fly.io:**
```bash
fly logs
```

**Docker:**
```bash
docker logs -f faucet-bot
```

### Check Master Wallet Balance

```bash
curl https://your-app-url.com/status
```

### View Request History

```bash
curl https://your-app-url.com/requests
```

### Manual Faucet Claim (Emergency)

SSH into your deployment and run:

**Railway:**
```bash
railway run npm run claim
```

**Fly.io:**
```bash
fly ssh console
cd /app/faucet-bot
npm run claim
```

---

## 🚀 Recommended Deployment Path

**For beginners**: Start with **Railway.app**
1. Easiest setup (10 minutes)
2. Automatic HTTPS
3. Good monitoring
4. $5/month is reasonable

**For free tier testing**: Use **Render.com**
1. Free tier available
2. Good for initial testing
3. Upgrade to $7/month for production

**For production**: Consider **Fly.io** or **VPS**
1. More control
2. Better performance
3. Global deployment options

---

## 💡 Next Steps After Deployment

1. **Monitor First 24h**: Watch logs to ensure claim automation works
2. **Test Frontend Integration**: Verify users can request ETH
3. **Set Up Alerts**: Configure notifications for errors
4. **Add Monitoring**: Consider Sentry for error tracking
5. **Scale if Needed**: Increase resources if traffic grows
6. **Backup Data**: Regularly backup `data/` directory
7. **Update Regularly**: Keep dependencies updated

---

## 📞 Support

If you encounter issues:
1. Check platform-specific logs
2. Review `data/screenshots/` for Playwright errors
3. Test endpoints with `curl`
4. Verify environment variables
5. Check GitHub Issues

---

**Happy Deploying! 🎉**
