# 📊 ByteStrike Mark Price Chart Implementation Guide

Complete guide for implementing real-time mark price charts on the ByteStrike frontend using Supabase as the backend.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Database Schema Setup](#step-1-supabase-database-schema)
3. [Price Indexer Service](#step-2-price-indexer-service)
4. [Frontend Chart Component](#step-3-frontend-chart-component)
5. [Environment Configuration](#step-4-environment-configuration)
6. [Integration](#step-5-integration)
7. [Supabase Setup](#step-6-supabase-setup)
8. [Deployment Checklist](#deployment-checklist)
9. [Alternative Simple Approach](#alternative-simpler-approach-no-indexer)
10. [FAQ and Troubleshooting](#faq-and-troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     DATA FLOW                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Sepolia Blockchain                                          │
│  (vAMM Contract)                                             │
│         │                                                     │
│         │ getMarkPrice()                                     │
│         ▼                                                     │
│  Price Indexer Service                                       │
│  (Node.js/Python)                                            │
│         │                                                     │
│         │ INSERT price data                                  │
│         ▼                                                     │
│  Supabase Database                                           │
│  (PostgreSQL)                                                │
│         │                                                     │
│         │ REST API / Realtime                                │
│         ▼                                                     │
│  React Frontend                                              │
│  (Chart Component)                                           │
│         │                                                     │
│         ▼                                                     │
│  User Browser                                                │
│  (Interactive Chart)                                         │
└─────────────────────────────────────────────────────────────┘
```

**Key Components:**
- **vAMM Contract**: Source of truth for mark prices on Sepolia
- **Price Indexer**: Background service that fetches prices every minute (or custom interval)
- **Supabase**: PostgreSQL database with real-time subscriptions
- **React Frontend**: Chart visualization using Recharts library

**Data Flow:**
1. Indexer fetches `getMarkPrice()` from vAMM contract
2. Stores price + timestamp in Supabase
3. Frontend queries historical data on load
4. Frontend subscribes to real-time updates
5. Chart updates automatically when new prices arrive

---

## STEP 1: Supabase Database Schema

### 1.1 Create `market_prices` Table

This table stores raw price data points at high frequency (every minute or less).

```sql
CREATE TABLE market_prices (
  id BIGSERIAL PRIMARY KEY,
  market_id TEXT NOT NULL,                    -- "H100-PERP", "ETH-PERP", etc.
  market_address TEXT NOT NULL,               -- vAMM contract address
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mark_price NUMERIC(30, 18) NOT NULL,        -- Mark price in 1e18 format (raw wei)
  mark_price_usd NUMERIC(20, 6) NOT NULL,     -- Human-readable USD price
  index_price NUMERIC(30, 18),                -- Index/oracle price (optional)
  funding_rate NUMERIC(20, 6),                -- Funding rate (optional)
  open_interest NUMERIC(30, 18),              -- Total open interest (optional)
  volume_24h NUMERIC(30, 18),                 -- 24h volume (optional)

  -- Constraint to prevent duplicate timestamps per market
  CONSTRAINT unique_market_timestamp UNIQUE(market_id, timestamp)
);

-- Index for time-series queries (fast lookups by market + time range)
CREATE INDEX idx_market_prices_market_time
  ON market_prices(market_id, timestamp DESC);

-- Index for recent prices across all markets
CREATE INDEX idx_market_prices_timestamp
  ON market_prices(timestamp DESC);

-- Add comment for documentation
COMMENT ON TABLE market_prices IS 'Stores high-frequency mark price data for perpetual markets';
```

### 1.2 Create `market_candles` Table (For OHLCV Data)

This table stores aggregated candlestick data for different timeframes.

```sql
CREATE TABLE market_candles (
  id BIGSERIAL PRIMARY KEY,
  market_id TEXT NOT NULL,
  interval TEXT NOT NULL,                     -- '1m', '5m', '15m', '1h', '4h', '1d'
  timestamp TIMESTAMPTZ NOT NULL,
  open NUMERIC(20, 6) NOT NULL,               -- Opening price for the candle
  high NUMERIC(20, 6) NOT NULL,               -- Highest price in the interval
  low NUMERIC(20, 6) NOT NULL,                -- Lowest price in the interval
  close NUMERIC(20, 6) NOT NULL,              -- Closing price for the candle
  volume NUMERIC(30, 18) DEFAULT 0,           -- Trading volume in the interval

  -- Unique constraint: one candle per market/interval/timestamp
  CONSTRAINT unique_market_interval_time
    UNIQUE(market_id, interval, timestamp)
);

-- Index for efficient candle queries
CREATE INDEX idx_market_candles_market_interval_time
  ON market_candles(market_id, interval, timestamp DESC);

COMMENT ON TABLE market_candles IS 'Aggregated OHLCV candlestick data for various timeframes';
```

### 1.3 Create Helper Functions

#### Function: Get Latest Price

```sql
-- Function to get the most recent price for a market
CREATE OR REPLACE FUNCTION get_latest_price(p_market_id TEXT)
RETURNS TABLE (
  mark_price_usd NUMERIC,
  timestamp TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT mp.mark_price_usd, mp.timestamp
  FROM market_prices mp
  WHERE mp.market_id = p_market_id
  ORDER BY mp.timestamp DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_latest_price IS 'Returns the most recent mark price for a given market';

-- Usage example:
-- SELECT * FROM get_latest_price('H100-PERP');
```

#### Function: Get Price History with Aggregation

```sql
-- Function to get aggregated price history
CREATE OR REPLACE FUNCTION get_price_history(
  p_market_id TEXT,
  p_interval TEXT DEFAULT '1h',  -- '5m', '15m', '1h', '4h', '1d'
  p_limit INT DEFAULT 100
)
RETURNS TABLE (
  timestamp TIMESTAMPTZ,
  price NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    date_trunc(p_interval, mp.timestamp) as timestamp,
    AVG(mp.mark_price_usd) as price
  FROM market_prices mp
  WHERE mp.market_id = p_market_id
    AND mp.timestamp > NOW() - INTERVAL '7 days'  -- Limit to recent data
  GROUP BY date_trunc(p_interval, mp.timestamp)
  ORDER BY timestamp DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_price_history IS 'Returns aggregated price history for specified interval';

-- Usage example:
-- SELECT * FROM get_price_history('H100-PERP', '1h', 100);
```

#### Function: Calculate Price Statistics

```sql
-- Function to get 24h price statistics
CREATE OR REPLACE FUNCTION get_24h_stats(p_market_id TEXT)
RETURNS TABLE (
  current_price NUMERIC,
  high_24h NUMERIC,
  low_24h NUMERIC,
  volume_24h NUMERIC,
  price_change_24h NUMERIC,
  price_change_pct_24h NUMERIC
) AS $$
DECLARE
  v_current NUMERIC;
  v_24h_ago NUMERIC;
BEGIN
  -- Get current price
  SELECT mark_price_usd INTO v_current
  FROM market_prices
  WHERE market_id = p_market_id
  ORDER BY timestamp DESC
  LIMIT 1;

  -- Get price 24h ago
  SELECT mark_price_usd INTO v_24h_ago
  FROM market_prices
  WHERE market_id = p_market_id
    AND timestamp <= NOW() - INTERVAL '24 hours'
  ORDER BY timestamp DESC
  LIMIT 1;

  RETURN QUERY
  SELECT
    v_current,
    MAX(mp.mark_price_usd) as high_24h,
    MIN(mp.mark_price_usd) as low_24h,
    COALESCE(SUM(mp.volume_24h), 0) as volume_24h,
    (v_current - v_24h_ago) as price_change_24h,
    CASE
      WHEN v_24h_ago > 0 THEN ((v_current - v_24h_ago) / v_24h_ago * 100)
      ELSE 0
    END as price_change_pct_24h
  FROM market_prices mp
  WHERE mp.market_id = p_market_id
    AND mp.timestamp > NOW() - INTERVAL '24 hours';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_24h_stats IS 'Returns 24-hour price statistics for a market';
```

### 1.4 Data Retention Policy (Optional)

To prevent database bloat, set up a data retention policy:

```sql
-- Function to clean up old price data
CREATE OR REPLACE FUNCTION cleanup_old_prices()
RETURNS void AS $$
BEGIN
  -- Delete raw prices older than 30 days
  DELETE FROM market_prices
  WHERE timestamp < NOW() - INTERVAL '30 days';

  -- Delete candles older than 90 days
  DELETE FROM market_candles
  WHERE timestamp < NOW() - INTERVAL '90 days';

  RAISE NOTICE 'Cleaned up old price data';
END;
$$ LANGUAGE plpgsql;

-- Schedule cleanup (run daily via pg_cron extension or external cron job)
-- SELECT cron.schedule('cleanup-prices', '0 2 * * *', 'SELECT cleanup_old_prices()');
```

---

## STEP 2: Price Indexer Service

The indexer is a background service that continuously fetches mark prices from the blockchain and stores them in Supabase.

### 2.1 Project Setup

Create a new Node.js project:

```bash
mkdir price-indexer
cd price-indexer
npm init -y
```

### 2.2 Install Dependencies

```bash
npm install @supabase/supabase-js ethers node-cron dotenv
npm install --save-dev nodemon
```

### 2.3 Create `package.json`

```json
{
  "name": "bytestrike-price-indexer",
  "version": "1.0.0",
  "type": "module",
  "description": "Price indexer for ByteStrike perpetual markets",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "dev": "nodemon index.js"
  },
  "dependencies": {
    "@supabase/supabase-js": "^2.39.0",
    "ethers": "^6.9.0",
    "node-cron": "^3.0.3",
    "dotenv": "^16.3.1"
  },
  "devDependencies": {
    "nodemon": "^3.0.2"
  }
}
```

### 2.4 Create `.env` File

```env
# Supabase Configuration
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_KEY=your-service-role-key-here

# Blockchain RPC
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY

# Indexer Configuration
POLL_INTERVAL_SECONDS=60
LOG_LEVEL=info
```

⚠️ **Security Note:** Use the **service role key**, not the anon key, for the indexer. The service role key bypasses RLS policies.

### 2.5 Create `index.js` - Main Indexer

```javascript
// price-indexer/index.js
import { createClient } from '@supabase/supabase-js';
import { ethers } from 'ethers';
import cron from 'node-cron';
import dotenv from 'dotenv';

dotenv.config();

// Configuration
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const POLL_INTERVAL = parseInt(process.env.POLL_INTERVAL_SECONDS || '60');

// Validate environment variables
if (!SUPABASE_URL || !SUPABASE_KEY || !RPC_URL) {
  console.error('❌ Missing required environment variables!');
  console.error('Required: SUPABASE_URL, SUPABASE_SERVICE_KEY, SEPOLIA_RPC_URL');
  process.exit(1);
}

// Initialize clients
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
const provider = new ethers.JsonRpcProvider(RPC_URL);

// vAMM ABI - Only the functions we need
const VAMM_ABI = [
  'function getMarkPrice() external view returns (uint256)',
  'function getIndexPrice() external view returns (uint256)',
  'function getCurrentFundingRate() external view returns (int256)',
];

// Markets to track
const MARKETS = [
  {
    id: 'H100-PERP',
    vammAddress: '0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85',
    name: 'H100 GPU Perpetual',
    description: 'H100 GPU rental futures at $3.79/hour',
  },
  // Add more markets here as they are deployed
  // {
  //   id: 'A100-PERP',
  //   vammAddress: '0x...',
  //   name: 'A100 GPU Perpetual',
  // },
];

/**
 * Fetch mark price and store in Supabase
 */
async function fetchAndStorePrice(market) {
  try {
    console.log(`[${market.id}] Fetching price...`);

    const vamm = new ethers.Contract(market.vammAddress, VAMM_ABI, provider);

    // Fetch mark price (required)
    const markPriceRaw = await vamm.getMarkPrice();
    const markPriceUsd = parseFloat(ethers.formatUnits(markPriceRaw, 18));

    // Fetch additional data (optional - handle failures gracefully)
    let indexPrice = null;
    let fundingRate = null;

    try {
      const indexPriceRaw = await vamm.getIndexPrice();
      indexPrice = ethers.formatUnits(indexPriceRaw, 18);
    } catch (e) {
      console.log(`[${market.id}] Index price not available:`, e.message);
    }

    try {
      const fundingRateRaw = await vamm.getCurrentFundingRate();
      fundingRate = parseFloat(ethers.formatUnits(fundingRateRaw, 18));
    } catch (e) {
      console.log(`[${market.id}] Funding rate not available:`, e.message);
    }

    // Prepare data for insertion
    const priceData = {
      market_id: market.id,
      market_address: market.vammAddress.toLowerCase(),
      mark_price: markPriceRaw.toString(),
      mark_price_usd: markPriceUsd,
      index_price: indexPrice,
      funding_rate: fundingRate,
      timestamp: new Date().toISOString(),
    };

    // Insert into Supabase
    const { data, error } = await supabase
      .from('market_prices')
      .insert(priceData)
      .select();

    if (error) {
      // Handle duplicate key error gracefully
      if (error.code === '23505') {
        console.log(`[${market.id}] ⚠️  Duplicate timestamp, skipping...`);
        return { market: market.id, price: markPriceUsd, success: true, skipped: true };
      }

      console.error(`[${market.id}] ❌ Error storing price:`, error.message);
      return { market: market.id, error: error.message, success: false };
    }

    console.log(`[${market.id}] ✅ Stored price: $${markPriceUsd.toFixed(4)}`);

    return { market: market.id, price: markPriceUsd, success: true };
  } catch (error) {
    console.error(`[${market.id}] ❌ Error fetching price:`, error.message);
    return { market: market.id, error: error.message, success: false };
  }
}

/**
 * Fetch prices for all markets
 */
async function fetchAllPrices() {
  const timestamp = new Date().toISOString();
  console.log(`\n[${timestamp}] 🔄 Fetching prices for ${MARKETS.length} market(s)...`);

  try {
    // Fetch all prices in parallel
    const results = await Promise.all(
      MARKETS.map(market => fetchAndStorePrice(market))
    );

    // Calculate statistics
    const successful = results.filter(r => r.success && !r.skipped).length;
    const skipped = results.filter(r => r.skipped).length;
    const failed = results.filter(r => !r.success).length;

    console.log(`\n📊 Summary: ${successful} stored, ${skipped} skipped, ${failed} failed`);

    // Log price table
    console.log('\n📈 Current Prices:');
    console.table(
      results
        .filter(r => r.success)
        .map(r => ({
          Market: r.market,
          Price: r.price ? `$${r.price.toFixed(4)}` : 'N/A',
          Status: r.skipped ? 'Skipped' : 'Stored',
        }))
    );

  } catch (error) {
    console.error('❌ Error in fetchAllPrices:', error);
  }
}

/**
 * Health check - verify connections
 */
async function healthCheck() {
  console.log('🏥 Running health check...');

  // Check Supabase connection
  try {
    const { data, error } = await supabase.from('market_prices').select('id').limit(1);
    if (error) throw error;
    console.log('✅ Supabase connection OK');
  } catch (error) {
    console.error('❌ Supabase connection failed:', error.message);
    return false;
  }

  // Check RPC connection
  try {
    const blockNumber = await provider.getBlockNumber();
    console.log(`✅ RPC connection OK (block: ${blockNumber})`);
  } catch (error) {
    console.error('❌ RPC connection failed:', error.message);
    return false;
  }

  // Check vAMM contracts
  for (const market of MARKETS) {
    try {
      const vamm = new ethers.Contract(market.vammAddress, VAMM_ABI, provider);
      const price = await vamm.getMarkPrice();
      console.log(`✅ ${market.id} vAMM OK (price: $${ethers.formatUnits(price, 18)})`);
    } catch (error) {
      console.error(`❌ ${market.id} vAMM failed:`, error.message);
      return false;
    }
  }

  console.log('✅ All health checks passed!\n');
  return true;
}

/**
 * Main entry point
 */
async function main() {
  console.log('🚀 ByteStrike Price Indexer Starting...');
  console.log(`📊 Tracking ${MARKETS.length} market(s)`);
  console.log(`⏱️  Poll interval: ${POLL_INTERVAL} seconds`);
  console.log(`🌐 RPC: ${RPC_URL.substring(0, 50)}...`);
  console.log('');

  // Run health check first
  const healthy = await healthCheck();
  if (!healthy) {
    console.error('❌ Health check failed! Exiting...');
    process.exit(1);
  }

  // Fetch prices immediately on start
  await fetchAllPrices();

  // Schedule periodic fetching
  if (POLL_INTERVAL >= 60) {
    // Use cron for minute-based intervals
    const cronExpression = `*/${Math.floor(POLL_INTERVAL / 60)} * * * *`;
    console.log(`⏰ Scheduling cron job: ${cronExpression}`);

    cron.schedule(cronExpression, () => {
      fetchAllPrices();
    });
  } else {
    // Use setInterval for sub-minute intervals
    console.log(`⏰ Scheduling interval: every ${POLL_INTERVAL} seconds`);
    setInterval(fetchAllPrices, POLL_INTERVAL * 1000);
  }

  console.log('✅ Indexer running! Press Ctrl+C to stop.\n');
}

// Handle graceful shutdown
process.on('SIGINT', () => {
  console.log('\n👋 Shutting down gracefully...');
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('\n👋 Received SIGTERM, shutting down...');
  process.exit(0);
});

// Start the indexer
main().catch((error) => {
  console.error('💥 Fatal error:', error);
  process.exit(1);
});
```

### 2.6 Create `.gitignore`

```
node_modules/
.env
npm-debug.log
.DS_Store
```

### 2.7 Run the Indexer Locally

```bash
# Development mode (auto-restart on changes)
npm run dev

# Production mode
npm start
```

**Expected Output:**
```
🚀 ByteStrike Price Indexer Starting...
📊 Tracking 1 market(s)
⏱️  Poll interval: 60 seconds
🌐 RPC: https://sepolia.infura.io/v3/...

🏥 Running health check...
✅ Supabase connection OK
✅ RPC connection OK (block: 5234567)
✅ H100-PERP vAMM OK (price: 3.79)
✅ All health checks passed!

[2025-11-27T12:00:00.000Z] 🔄 Fetching prices for 1 market(s)...
[H100-PERP] Fetching price...
[H100-PERP] ✅ Stored price: $3.7900

📊 Summary: 1 stored, 0 skipped, 0 failed

📈 Current Prices:
┌─────────┬────────────┬──────────┬─────────┐
│ (index) │   Market   │  Price   │ Status  │
├─────────┼────────────┼──────────┼─────────┤
│    0    │ 'H100-PERP'│ '$3.7900'│ 'Stored'│
└─────────┴────────────┴──────────┴─────────┘
```

### 2.8 Deployment Options

#### Option 1: Railway.app (Recommended - Free Tier)

1. Create account at [railway.app](https://railway.app)
2. Click "New Project" → "Deploy from GitHub"
3. Connect your GitHub repo with the `price-indexer` folder
4. Add environment variables in Railway dashboard
5. Deploy! Railway auto-detects Node.js and runs `npm start`

**Pros:**
- ✅ Free tier with 500 hours/month
- ✅ Auto-deploys on git push
- ✅ Built-in logging
- ✅ Simple to use

#### Option 2: Render.com

1. Create account at [render.com](https://render.com)
2. New → Background Worker
3. Connect GitHub repo
4. Set build command: `npm install`
5. Set start command: `npm start`
6. Add environment variables
7. Deploy

**Pros:**
- ✅ Free tier available
- ✅ Auto-scaling

**Cons:**
- ⚠️ Free tier sleeps after 15 min of inactivity

#### Option 3: Heroku

```bash
# Install Heroku CLI
brew install heroku/brew/heroku  # macOS
# or download from heroku.com

# Login and create app
heroku login
heroku create bytestrike-price-indexer

# Set environment variables
heroku config:set SUPABASE_URL=https://...
heroku config:set SUPABASE_SERVICE_KEY=...
heroku config:set SEPOLIA_RPC_URL=https://...

# Deploy
git push heroku main

# View logs
heroku logs --tail
```

**Pros:**
- ✅ Rock solid reliability
- ✅ Great logging

**Cons:**
- ❌ No free tier anymore (starts at $7/month)

#### Option 4: VPS (DigitalOcean, AWS EC2)

```bash
# SSH into your server
ssh user@your-server-ip

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Clone your repo
git clone https://github.com/your-username/byte-strike.git
cd byte-strike/price-indexer

# Install dependencies
npm install

# Create .env file
nano .env
# (paste your environment variables)

# Install PM2 (process manager)
sudo npm install -g pm2

# Start the indexer
pm2 start index.js --name bytestrike-indexer

# Set up auto-restart on server reboot
pm2 startup
pm2 save

# View logs
pm2 logs bytestrike-indexer
```

**Pros:**
- ✅ Full control
- ✅ Can run multiple services

**Cons:**
- ❌ More complex setup
- ❌ You manage everything

---

## STEP 3: Frontend Chart Component

### 3.1 Install Dependencies

```bash
cd bytestrike3
npm install recharts date-fns @supabase/supabase-js
```

**Package Overview:**
- `recharts`: React charting library (lightweight, ~60KB)
- `date-fns`: Date formatting utilities
- `@supabase/supabase-js`: Supabase client for React

### 3.2 Create Chart Component

Create `bytestrike3/src/components/PriceChart.jsx`:

```jsx
import { useState, useEffect } from 'react';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid
} from 'recharts';
import { createClient } from '@supabase/supabase-js';
import { format, subHours, subDays } from 'date-fns';
import './PriceChart.css';

// Initialize Supabase client
const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
);

/**
 * PriceChart Component
 *
 * Displays real-time mark price chart for a given market
 *
 * Props:
 * - marketId: string - Market identifier (e.g., 'H100-PERP')
 * - interval: string - Time interval ('5m', '15m', '1h', '4h', '1d')
 * - limit: number - Max data points to display
 * - height: number - Chart height in pixels (default: 400)
 */
export function PriceChart({
  marketId = 'H100-PERP',
  interval = '1h',
  limit = 100,
  height = 400
}) {
  const [priceData, setPriceData] = useState([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedInterval, setSelectedInterval] = useState(interval);
  const [latestPrice, setLatestPrice] = useState(null);
  const [priceChange24h, setPriceChange24h] = useState(null);

  /**
   * Fetch historical price data from Supabase
   */
  const fetchPriceHistory = async () => {
    setIsLoading(true);
    setError(null);

    try {
      // Calculate time range based on interval
      const timeRange = getTimeRange(selectedInterval, limit);

      const { data, error: fetchError } = await supabase
        .from('market_prices')
        .select('timestamp, mark_price_usd')
        .eq('market_id', marketId)
        .gte('timestamp', timeRange)
        .order('timestamp', { ascending: true })
        .limit(limit);

      if (fetchError) throw fetchError;

      if (!data || data.length === 0) {
        setError('No price data available for this market');
        setPriceData([]);
        return;
      }

      // Transform data for chart
      const chartData = data.map(item => ({
        timestamp: new Date(item.timestamp).getTime(),
        price: parseFloat(item.mark_price_usd),
        formattedTime: format(new Date(item.timestamp), 'MMM dd HH:mm'),
      }));

      setPriceData(chartData);

      // Set latest price
      if (chartData.length > 0) {
        const latest = chartData[chartData.length - 1].price;
        const first = chartData[0].price;

        setLatestPrice(latest);

        // Calculate 24h change
        if (chartData.length >= 2) {
          const change = ((latest - first) / first) * 100;
          setPriceChange24h(change);
        }
      }
    } catch (err) {
      console.error('Error fetching price history:', err);
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  /**
   * Calculate time range for query
   */
  const getTimeRange = (interval, limit) => {
    const now = new Date();

    switch (interval) {
      case '5m':
        return subHours(now, Math.ceil(limit * 5 / 60));
      case '15m':
        return subHours(now, Math.ceil(limit * 15 / 60));
      case '1h':
        return subHours(now, limit);
      case '4h':
        return subHours(now, limit * 4);
      case '1d':
        return subDays(now, limit);
      default:
        return subHours(now, 24);
    }
  };

  /**
   * Subscribe to real-time price updates
   */
  useEffect(() => {
    // Initial fetch
    fetchPriceHistory();

    // Subscribe to new price inserts
    const subscription = supabase
      .channel(`market_prices_${marketId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'market_prices',
          filter: `market_id=eq.${marketId}`,
        },
        (payload) => {
          console.log('📊 New price update:', payload.new);

          const newPrice = {
            timestamp: new Date(payload.new.timestamp).getTime(),
            price: parseFloat(payload.new.mark_price_usd),
            formattedTime: format(new Date(payload.new.timestamp), 'MMM dd HH:mm'),
          };

          // Add new price and remove oldest if over limit
          setPriceData(prev => {
            const updated = [...prev, newPrice];
            return updated.slice(-limit);
          });

          setLatestPrice(newPrice.price);
        }
      )
      .subscribe();

    // Cleanup subscription on unmount
    return () => {
      subscription.unsubscribe();
    };
  }, [marketId, selectedInterval, limit]);

  /**
   * Custom tooltip component
   */
  const CustomTooltip = ({ active, payload }) => {
    if (active && payload && payload.length) {
      const data = payload[0].payload;
      return (
        <div className="price-chart-tooltip">
          <p className="tooltip-time">{data.formattedTime}</p>
          <p className="tooltip-price">${data.price.toFixed(4)}</p>
        </div>
      );
    }
    return null;
  };

  /**
   * Handle interval change
   */
  const handleIntervalChange = (newInterval) => {
    setSelectedInterval(newInterval);
  };

  // Determine if price is up or down
  const isPositive = priceChange24h !== null && priceChange24h >= 0;

  // Loading state
  if (isLoading) {
    return (
      <div className="price-chart-container loading">
        <div className="loading-spinner">
          <div className="spinner"></div>
          <p>Loading price data...</p>
        </div>
      </div>
    );
  }

  // Error state
  if (error) {
    return (
      <div className="price-chart-container error">
        <div className="error-message">
          <span className="error-icon">⚠️</span>
          <p>{error}</p>
          <button onClick={fetchPriceHistory} className="retry-button">
            Retry
          </button>
        </div>
      </div>
    );
  }

  // Empty state
  if (priceData.length === 0) {
    return (
      <div className="price-chart-container empty">
        <div className="empty-state">
          <span className="empty-icon">📊</span>
          <p>No price data available</p>
          <p className="empty-subtitle">Price data will appear here once the indexer starts collecting prices</p>
        </div>
      </div>
    );
  }

  return (
    <div className="price-chart-container">
      {/* Header with price info and interval selector */}
      <div className="price-chart-header">
        <div className="price-info">
          <h3 className="current-price">
            ${latestPrice?.toFixed(4) || '—'}
          </h3>
          {priceChange24h !== null && (
            <span className={`price-change ${isPositive ? 'positive' : 'negative'}`}>
              {isPositive ? '+' : ''}{priceChange24h.toFixed(2)}%
            </span>
          )}
          <span className="price-label">
            Mark Price
          </span>
        </div>

        <div className="interval-selector">
          {['5m', '15m', '1h', '4h', '1d'].map(int => (
            <button
              key={int}
              className={`interval-btn ${selectedInterval === int ? 'active' : ''}`}
              onClick={() => handleIntervalChange(int)}
              title={`${int} timeframe`}
            >
              {int}
            </button>
          ))}
        </div>
      </div>

      {/* Chart */}
      <ResponsiveContainer width="100%" height={height}>
        <LineChart
          data={priceData}
          margin={{ top: 5, right: 20, left: 10, bottom: 5 }}
        >
          <CartesianGrid strokeDasharray="3 3" stroke="#2a2a2a" />

          <XAxis
            dataKey="timestamp"
            domain={['auto', 'auto']}
            type="number"
            scale="time"
            stroke="#888"
            tick={{ fontSize: 12, fill: '#888' }}
            tickFormatter={(timestamp) => format(new Date(timestamp), 'HH:mm')}
          />

          <YAxis
            stroke="#888"
            tick={{ fontSize: 12, fill: '#888' }}
            domain={['auto', 'auto']}
            tickFormatter={(value) => `$${value.toFixed(2)}`}
          />

          <Tooltip content={<CustomTooltip />} />

          <Line
            type="monotone"
            dataKey="price"
            stroke={isPositive ? '#00ff88' : '#ff4444'}
            strokeWidth={2}
            dot={false}
            animationDuration={300}
          />
        </LineChart>
      </ResponsiveContainer>

      {/* Footer with last update time */}
      <div className="price-chart-footer">
        <span className="last-update">
          Last updated: {priceData.length > 0
            ? format(new Date(priceData[priceData.length - 1].timestamp), 'MMM dd, HH:mm:ss')
            : '—'}
        </span>
        <span className="data-points">
          {priceData.length} data points
        </span>
      </div>
    </div>
  );
}

export default PriceChart;
```

### 3.3 Create Styles

Create `bytestrike3/src/components/PriceChart.css`:

```css
/* Price Chart Container */
.price-chart-container {
  background: linear-gradient(135deg, #1a1a1a 0%, #1f1f1f 100%);
  border-radius: 16px;
  padding: 24px;
  margin: 20px 0;
  border: 1px solid #333;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
  transition: all 0.3s ease;
}

.price-chart-container:hover {
  border-color: #00ff88;
  box-shadow: 0 4px 24px rgba(0, 255, 136, 0.1);
}

/* Loading State */
.price-chart-container.loading {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 400px;
}

.loading-spinner {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 16px;
  color: #888;
}

.spinner {
  width: 40px;
  height: 40px;
  border: 3px solid #333;
  border-top-color: #00ff88;
  border-radius: 50%;
  animation: spin 1s linear infinite;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

/* Error State */
.price-chart-container.error {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 400px;
}

.error-message {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 16px;
  color: #ff4444;
  text-align: center;
}

.error-icon {
  font-size: 48px;
}

.retry-button {
  background: #ff4444;
  color: white;
  border: none;
  padding: 10px 20px;
  border-radius: 8px;
  cursor: pointer;
  font-weight: 600;
  transition: all 0.2s;
}

.retry-button:hover {
  background: #ff6666;
  transform: translateY(-2px);
}

/* Empty State */
.price-chart-container.empty {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 400px;
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  color: #888;
  text-align: center;
}

.empty-icon {
  font-size: 64px;
  opacity: 0.5;
}

.empty-subtitle {
  font-size: 14px;
  color: #666;
  max-width: 300px;
}

/* Chart Header */
.price-chart-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 24px;
  flex-wrap: wrap;
  gap: 16px;
}

.price-info {
  display: flex;
  align-items: baseline;
  gap: 12px;
  flex-wrap: wrap;
}

.current-price {
  font-size: 36px;
  font-weight: 700;
  color: #fff;
  margin: 0;
  letter-spacing: -0.5px;
}

.price-change {
  font-size: 20px;
  font-weight: 600;
  padding: 4px 12px;
  border-radius: 6px;
  animation: pulse 2s ease-in-out infinite;
}

.price-change.positive {
  color: #00ff88;
  background: rgba(0, 255, 136, 0.1);
}

.price-change.negative {
  color: #ff4444;
  background: rgba(255, 68, 68, 0.1);
}

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.8; }
}

.price-label {
  color: #888;
  font-size: 14px;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

/* Interval Selector */
.interval-selector {
  display: flex;
  gap: 8px;
  background: #0a0a0a;
  padding: 4px;
  border-radius: 8px;
}

.interval-btn {
  background: transparent;
  color: #888;
  border: none;
  padding: 8px 16px;
  border-radius: 6px;
  cursor: pointer;
  font-size: 13px;
  font-weight: 600;
  transition: all 0.2s;
  user-select: none;
}

.interval-btn:hover {
  background: #1a1a1a;
  color: #fff;
}

.interval-btn.active {
  background: #00ff88;
  color: #000;
  box-shadow: 0 2px 8px rgba(0, 255, 136, 0.3);
}

/* Tooltip */
.price-chart-tooltip {
  background: rgba(0, 0, 0, 0.95);
  border: 1px solid #00ff88;
  padding: 10px 16px;
  border-radius: 8px;
  backdrop-filter: blur(10px);
}

.tooltip-time {
  color: #888;
  font-size: 12px;
  margin: 0 0 4px 0;
  font-weight: 500;
}

.tooltip-price {
  color: #fff;
  font-size: 18px;
  font-weight: 700;
  margin: 0;
  letter-spacing: -0.3px;
}

/* Chart Footer */
.price-chart-footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 16px;
  padding-top: 16px;
  border-top: 1px solid #2a2a2a;
  font-size: 12px;
  color: #666;
}

.last-update, .data-points {
  display: flex;
  align-items: center;
  gap: 6px;
}

/* Responsive Design */
@media (max-width: 768px) {
  .price-chart-container {
    padding: 16px;
  }

  .price-chart-header {
    flex-direction: column;
    align-items: flex-start;
  }

  .current-price {
    font-size: 28px;
  }

  .price-change {
    font-size: 16px;
  }

  .interval-selector {
    width: 100%;
    justify-content: space-between;
  }

  .interval-btn {
    flex: 1;
    padding: 8px 12px;
    font-size: 12px;
  }

  .price-chart-footer {
    flex-direction: column;
    gap: 8px;
    align-items: flex-start;
  }
}

@media (max-width: 480px) {
  .current-price {
    font-size: 24px;
  }

  .price-change {
    font-size: 14px;
  }
}
```

---

## STEP 4: Environment Configuration

### 4.1 Add to `bytestrike3/.env`

Create or update your `.env` file:

```env
# Supabase Configuration
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key-here

# Optional: API keys for other services
VITE_INFURA_API_KEY=your-infura-key
```

⚠️ **Security Note:** The anon key is safe to use in the frontend because it only has read access (enforced by RLS policies).

### 4.2 Update `.env.example`

```env
# Supabase (required for price charts)
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key

# RPC Endpoints
VITE_SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
```

### 4.3 Update `.gitignore`

Ensure `.env` is ignored:

```
# Environment variables
.env
.env.local
.env.production
```

---

## STEP 5: Integration

### 5.1 Update `tradingpanel.jsx`

Add the chart to your trading panel:

```jsx
import { PriceChart } from './components/PriceChart';
import { MARKET_IDS } from '../contracts/addresses';

export function TradingPanel() {
  // Your existing code...

  return (
    <div className="trading-panel-container">
      <div className="trading-panel-header">
        <h2>H100 GPU Perpetual</h2>
        <span className="market-info">$3.79/hour</span>
      </div>

      {/* Add Price Chart */}
      <PriceChart
        marketId="H100-PERP"
        interval="1h"
        limit={100}
        height={400}
      />

      {/* Your existing trading UI */}
      <div className="trading-controls">
        {/* Long/Short buttons, etc. */}
      </div>

      {/* Position panel, etc. */}
    </div>
  );
}
```

### 5.2 Alternative: Standalone Chart Page

Create a dedicated page for charts at `bytestrike3/src/pages/Charts.jsx`:

```jsx
import { PriceChart } from '../components/PriceChart';
import { MARKETS } from '../contracts/addresses';
import './Charts.css';

export function ChartsPage() {
  return (
    <div className="charts-page">
      <h1>Market Charts</h1>

      <div className="charts-grid">
        {Object.values(MARKETS).map(market => (
          <div key={market.id} className="chart-card">
            <h2>{market.displayName}</h2>
            <PriceChart
              marketId={market.id}
              interval="1h"
              limit={168} // 1 week of hourly data
              height={350}
            />
          </div>
        ))}
      </div>
    </div>
  );
}
```

---

## STEP 6: Supabase Setup

### 6.1 Create Tables in Supabase

1. Go to your Supabase project dashboard
2. Navigate to **SQL Editor**
3. Click **New Query**
4. Copy and paste the SQL from [STEP 1](#step-1-supabase-database-schema)
5. Click **Run** to execute

### 6.2 Enable Row Level Security (RLS)

Run this SQL in the SQL Editor:

```sql
-- Enable RLS on tables
ALTER TABLE market_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE market_candles ENABLE ROW LEVEL SECURITY;

-- Policy: Allow public read access to price data
CREATE POLICY "Public read access on market_prices"
  ON market_prices
  FOR SELECT
  USING (true);

CREATE POLICY "Public read access on market_candles"
  ON market_candles
  FOR SELECT
  USING (true);

-- Policy: Only service role can insert data (for indexer)
CREATE POLICY "Service role can insert market_prices"
  ON market_prices
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "Service role can insert market_candles"
  ON market_candles
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- Policy: Prevent updates and deletes from public
CREATE POLICY "Prevent public updates on market_prices"
  ON market_prices
  FOR UPDATE
  USING (false);

CREATE POLICY "Prevent public deletes on market_prices"
  ON market_prices
  FOR DELETE
  USING (false);
```

### 6.3 Enable Realtime

1. Go to **Database** → **Replication**
2. Find the `market_prices` table
3. Click the toggle to enable replication
4. Select **INSERT** events only
5. Click **Save**

This allows the frontend to receive real-time updates when new prices are inserted.

### 6.4 Get Your API Keys

1. Go to **Settings** → **API**
2. Copy the following:
   - **Project URL**: `https://your-project.supabase.co`
   - **anon public key**: For frontend (safe to expose)
   - **service_role key**: For indexer (keep secret!)

---

## Deployment Checklist

### Phase 1: Basic Implementation ✅

- [ ] Create Supabase project
- [ ] Create `market_prices` table with indexes
- [ ] Set up RLS policies
- [ ] Enable Realtime on `market_prices`
- [ ] Deploy price indexer service (Railway/Render/VPS)
- [ ] Add chart component to frontend
- [ ] Test with real data from indexer
- [ ] Verify real-time updates work

### Phase 2: Enhanced Features 🚀

- [ ] Add `market_candles` table for OHLCV data
- [ ] Implement multiple timeframe support (5m, 15m, 1h, 4h, 1d)
- [ ] Create candlestick chart variant
- [ ] Add volume bars below price chart
- [ ] Show funding rate timeline
- [ ] Add technical indicators (Moving Averages, RSI, MACD)
- [ ] Add zoom/pan controls for chart
- [ ] Export chart as image feature

### Phase 3: Optimization ⚡

- [ ] Implement data aggregation for older data
  - Keep 1-minute data for 7 days
  - Aggregate to 1-hour for data older than 7 days
  - Aggregate to 1-day for data older than 30 days
- [ ] Add Redis caching layer for frequently accessed data
- [ ] Optimize database queries with proper indexes
- [ ] Implement pagination for large datasets
- [ ] Add database cleanup cron job (delete old data)
- [ ] Monitor indexer uptime and alerts
- [ ] Add error tracking (Sentry)

### Phase 4: Advanced Features 🎯

- [ ] Compare multiple markets on same chart
- [ ] Trading view from chart (click to trade)
- [ ] Add drawing tools (trend lines, support/resistance)
- [ ] Historical event markers (liquidations, funding rate changes)
- [ ] Market depth chart (orderbook visualization)
- [ ] Correlation analysis between markets
- [ ] Price alerts and notifications
- [ ] Mobile-optimized chart gestures

---

## Alternative: Simpler Approach (No Indexer)

If you don't want to manage a separate indexer service, you can fetch prices directly from the blockchain in your frontend. However, **this approach has significant limitations**.

### Direct RPC Approach

```jsx
import { ethers } from 'ethers';
import { useState, useEffect } from 'react';

const VAMM_ABI = ['function getMarkPrice() view returns (uint256)'];
const VAMM_ADDRESS = '0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85';

export function SimpleChart() {
  const [prices, setPrices] = useState([]);

  useEffect(() => {
    const provider = new ethers.JsonRpcProvider(
      'https://sepolia.infura.io/v3/YOUR_KEY'
    );

    const vamm = new ethers.Contract(VAMM_ADDRESS, VAMM_ABI, provider);

    // Fetch price every 10 seconds
    const interval = setInterval(async () => {
      const priceRaw = await vamm.getMarkPrice();
      const price = parseFloat(ethers.formatUnits(priceRaw, 18));

      setPrices(prev => [
        ...prev,
        { timestamp: Date.now(), price }
      ].slice(-100)); // Keep last 100 points
    }, 10000);

    return () => clearInterval(interval);
  }, []);

  return (
    <LineChart data={prices}>
      <Line dataKey="price" />
    </LineChart>
  );
}
```

### Pros and Cons

**Pros:**
- ✅ No backend infrastructure needed
- ✅ Simple to implement
- ✅ No database required

**Cons:**
- ❌ **No historical data** - Only shows data since page load
- ❌ **High RPC costs** - Every user makes constant RPC calls
- ❌ **Slower** - Network latency for each price fetch
- ❌ **Rate limiting** - Free RPC providers will block you
- ❌ **Poor UX** - Chart resets on page refresh
- ❌ **No real-time** - 10-second delays minimum

**Verdict:** Only use this for quick prototyping. For production, use the indexer approach.

---

## FAQ and Troubleshooting

### Q: How much does it cost to run?

**A:** Very cheap or free!

- **Supabase**: Free tier (500MB database, 2GB bandwidth/month) is enough for months
- **Indexer**: Free on Railway (500 hours/month) or $5/month VPS
- **RPC calls**: ~4,320 calls/month (1 per minute) - well within free tier limits

**Total cost: $0-5/month**

### Q: How do I add more markets?

In `price-indexer/index.js`, add to the `MARKETS` array:

```javascript
const MARKETS = [
  {
    id: 'H100-PERP',
    vammAddress: '0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85',
    name: 'H100 GPU Perpetual',
  },
  {
    id: 'A100-PERP',
    vammAddress: '0xYourNewVAMMAddress',
    name: 'A100 GPU Perpetual',
  },
];
```

Restart the indexer and it will automatically start tracking the new market.

### Q: Chart shows "No data available"

**Troubleshooting steps:**

1. Check if indexer is running:
   ```bash
   # If using Railway
   railway logs --tail

   # If using PM2
   pm2 logs bytestrike-indexer
   ```

2. Check if data is in Supabase:
   ```sql
   SELECT * FROM market_prices
   ORDER BY timestamp DESC
   LIMIT 10;
   ```

3. Check browser console for errors:
   - Open DevTools (F12)
   - Look for errors in Console tab
   - Check Network tab for failed API calls

4. Verify environment variables:
   ```bash
   # In bytestrike3/.env
   echo $VITE_SUPABASE_URL
   echo $VITE_SUPABASE_ANON_KEY
   ```

### Q: Real-time updates not working

**Possible causes:**

1. **Realtime not enabled on Supabase**
   - Go to Database → Replication
   - Enable replication for `market_prices` table

2. **Wrong channel subscription**
   - Check that `marketId` matches in both indexer and frontend
   - Verify filter: `filter: 'market_id=eq.H100-PERP'`

3. **Firewall/Network issues**
   - Realtime uses WebSockets (port 443)
   - Some corporate firewalls block WebSockets

4. **Multiple subscriptions**
   - Ensure you're properly cleaning up subscriptions in `useEffect` cleanup

### Q: Indexer keeps crashing

**Common issues:**

1. **RPC rate limiting**
   - Use a paid RPC provider (Alchemy, Infura paid tier)
   - Increase `POLL_INTERVAL_SECONDS` to reduce calls

2. **Out of memory**
   - Increase memory allocation on your hosting platform
   - Railway: Go to Settings → increase memory limit

3. **Invalid environment variables**
   - Double-check all env vars are set correctly
   - Ensure service role key, not anon key, for indexer

4. **Network timeouts**
   - Add retry logic with exponential backoff
   - Increase RPC timeout in ethers provider

### Q: Database is growing too large

**Solution: Implement data retention policy**

```sql
-- Delete raw prices older than 30 days
DELETE FROM market_prices
WHERE timestamp < NOW() - INTERVAL '30 days';

-- Keep aggregated candles for longer (90 days)
DELETE FROM market_candles
WHERE timestamp < NOW() - INTERVAL '90 days';
```

Set up a daily cron job to run this cleanup.

### Q: Can I use a different chart library?

**Yes!** Popular alternatives:

1. **TradingView Charting Library** (Best, but $$$)
   - Professional-grade charts
   - Costs $1,000/month for commercial use
   - Used by Binance, Coinbase, etc.

2. **Lightweight Charts** by TradingView (Free!)
   - Simplified version, free and open-source
   - Great performance
   - [Documentation](https://tradingview.github.io/lightweight-charts/)

3. **Chart.js**
   - Simpler than Recharts
   - More configuration needed

4. **D3.js**
   - Most powerful and flexible
   - Steep learning curve
   - Complete custom control

For ByteStrike, **Recharts is recommended** for its simplicity and React integration.

### Q: How do I show candlestick charts instead of line charts?

Replace `<Line>` with candlestick components:

```jsx
import { ComposedChart, Bar, Line } from 'recharts';

// Use ComposedChart for candlesticks
<ComposedChart data={candleData}>
  <Bar dataKey="volume" fill="#333" />

  {/* Custom candlestick rendering */}
  <Line type="monotone" dataKey="high" stroke="#00ff88" />
  <Line type="monotone" dataKey="low" stroke="#ff4444" />
</ComposedChart>
```

Better yet, use a library designed for candlesticks like **lightweight-charts**.

### Q: Performance is slow with lots of data

**Optimization techniques:**

1. **Limit data points**
   ```javascript
   // Instead of all data, use aggregated candles
   .limit(100) // Only fetch last 100 points
   ```

2. **Use React.memo**
   ```javascript
   export const PriceChart = React.memo(({ marketId, interval }) => {
     // Component code...
   });
   ```

3. **Debounce real-time updates**
   ```javascript
   const debouncedUpdate = debounce((newPrice) => {
     setPriceData(prev => [...prev, newPrice]);
   }, 1000); // Update chart max once per second
   ```

4. **Virtual scrolling for large datasets**
   - Only render visible data points
   - Load more as user scrolls/zooms

---

## Summary

This guide provides a complete, production-ready implementation of real-time price charts for ByteStrike.

**Architecture:**
- 📊 Supabase PostgreSQL database for data storage
- ⚙️ Node.js indexer service for continuous price fetching
- ⚛️ React + Recharts for visualization
- 🔄 Real-time updates via Supabase subscriptions

**Timeline:**
- **Day 1**: Database setup + indexer deployment (4-6 hours)
- **Day 2**: Frontend chart component (3-4 hours)
- **Day 3**: Testing, optimization, deployment (2-3 hours)

**Total: ~10 hours of development time**

**Monthly Cost: $0-5** (Railway free tier + Supabase free tier)

---

## Next Steps

1. ✅ Create Supabase project and tables
2. ✅ Deploy price indexer service
3. ✅ Integrate chart component into frontend
4. 🚀 Add more markets as they're deployed
5. 🎨 Customize chart styling to match your design
6. 📈 Implement advanced features (candlesticks, indicators, alerts)

---

**Need help?** Check the [ByteStrike documentation](./README.md) or open an issue on GitHub!

Happy charting! 📊🚀
