# Algo Node Heartbeat

A robust heartbeat monitoring script for Algorand nodes that sends health status to [Healthchecks.io](https://healthchecks.io/). The script only sends heartbeats when your node passes all health checks, ensuring you only get alerts when something is actually wrong.

## Features

- ✅ **Smart Health Checks**: Only sends heartbeat when node is healthy
  - Verifies Algorand service is running
  - Confirms node is synced (last block < 30 seconds ago)
  - Validates participation keys are registered
- 📊 **Comprehensive Stats**: Sends detailed node and system metrics
  - Node status (last block time, round, sync/catchup times)
  - System resources (CPU, memory, disk usage)
  - Service uptime and system load
  - Journal health monitoring
- 🔄 **Reliable Delivery**: Follows Healthchecks.io best practices
  - Automatic retry on transient failures
  - Proper timeouts to prevent hanging
  - Error handling and logging

## Prerequisites

- Linux system with systemd (Ubuntu, Debian, CentOS, etc.)
- Algorand node installed and running as a systemd service (`algorand.service`)
- `curl` installed
- Healthchecks.io account (free tier available)
- User with sudo access to run `goal` commands

## Setup Instructions

### 1. Get Your Healthchecks.io UUID

1. Sign up at [healthchecks.io](https://healthchecks.io/) (free account available)
2. Create a new check
3. Copy the **Ping URL** - it looks like: `https://hc-ping.com/your-uuid-here`
4. Save this URL - you'll need it in the next step

### 2. Install the Script

Clone this repository or download the files to your Algorand node:

```bash
# Option 1: Clone the repo
git clone https://github.com/solarstakealgo/algo-node-heartbeat.git
cd algo-node-heartbeat

# Option 2: Or just download the files directly
```

### 3. Configure the Script

Edit `heartbeat.sh` and update the default heartbeat URL (or use environment variable):

```bash
# In heartbeat.sh, line 15, replace with your UUID:
HEARTBEAT_URL="${HEARTBEAT_URL:-https://hc-ping.com/YOUR-UUID-HERE}"
```

**Or** set it via environment variable in the systemd service file (recommended).

### 4. Make Script Executable

```bash
chmod +x heartbeat.sh
```

### 5. Install Systemd Service and Timer

#### Option A: Install to Standard Location (Recommended)

```bash
# Copy files to systemd directory
sudo cp heartbeat.service /etc/systemd/system/
sudo cp heartbeat.timer /etc/systemd/system/

# Edit the service file to match your setup
sudo nano /etc/systemd/system/heartbeat.service
```

Update these lines in `heartbeat.service`:
- `User=zach` → Change to your username
- `ExecStart=/home/zach/heartbeat/heartbeat.sh` → Change to your script path
- `Environment="HEARTBEAT_URL=..."` → Add your Healthchecks.io UUID

#### Option B: Install to User Directory

If you prefer to keep it in your home directory:

```bash
# Create directory
mkdir -p ~/heartbeat
cp heartbeat.sh ~/heartbeat/
cp heartbeat.service ~/heartbeat/
cp heartbeat.timer ~/heartbeat/

# Edit service file
nano ~/heartbeat/heartbeat.service
```

Update paths in the service file to match your home directory.

### 6. Configure Algorand Data Path

If your Algorand data directory is not `/var/lib/algorand`, update line 16 in `heartbeat.sh`:

```bash
ALGORAND_DATA="/var/lib/algorand"  # Change to your path
```

Common locations:
- `/var/lib/algorand` (default)
- `~/algorand/node/data`
- Custom installation path

### 7. Test the Script Manually

Before enabling the service, test it:

```bash
# Set your heartbeat URL
export HEARTBEAT_URL="https://hc-ping.com/YOUR-UUID-HERE"

# Run the script
./heartbeat.sh

# Check Healthchecks.io - you should see a ping!
```

### 8. Enable and Start the Timer

```bash
# Reload systemd to pick up new files
sudo systemctl daemon-reload

# Enable the timer (starts on boot)
sudo systemctl enable heartbeat.timer

# Start the timer immediately
sudo systemctl start heartbeat.timer

# Check status
sudo systemctl status heartbeat.timer
sudo systemctl status heartbeat.service
```

### 9. Verify It's Working

1. Check the timer is active:
   ```bash
   sudo systemctl list-timers heartbeat.timer
   ```

2. Check recent service runs:
   ```bash
   sudo journalctl -u heartbeat.service -n 20
   ```

3. Visit your Healthchecks.io dashboard - you should see regular pings every 30 seconds!

## Configuration

### Timer Frequency

The default timer runs every 30 seconds. To change this, edit `heartbeat.timer`:

```ini
[Timer]
OnUnitActiveSec=30sec  # Change to your desired interval (e.g., 1min, 5min)
```

### Health Check Thresholds

The script skips heartbeat if:
- Algorand service is not running
- Last block time > 30 seconds (node not synced)
- No participation keys registered

To adjust the sync threshold, edit line 25 in `heartbeat.sh`:

```bash
SYNCED=$(awk -v t="$LAST_BLOCK_TIME" 'BEGIN {if (t < 30) print "1"; else print "0"}')
# Change 30 to your desired threshold (in seconds)
```

### Environment Variables

You can override configuration via environment variables in the systemd service:

```ini
[Service]
Environment="HEARTBEAT_URL=https://hc-ping.com/YOUR-UUID"
Environment="ALGORAND_DATA=/custom/path"
```

## Monitoring

### View Logs

```bash
# View recent heartbeat runs
sudo journalctl -u heartbeat.service -f

# View last 50 lines
sudo journalctl -u heartbeat.service -n 50

# View logs from today
sudo journalctl -u heartbeat.service --since today
```

### Healthchecks.io Dashboard

Your Healthchecks.io dashboard will show:
- ✅ **Green**: Node is healthy (heartbeat received)
- ⚠️ **Yellow**: Heartbeat missed (node might be down or unhealthy)
- ❌ **Red**: Check is down (no heartbeat for configured grace period)

## Troubleshooting

### Script exits silently (no heartbeat sent)

The script exits with code 0 if health checks fail. Check:

1. Is Algorand service running?
   ```bash
   sudo systemctl status algorand.service
   ```

2. Is node synced?
   ```bash
   sudo -u algorand goal node status
   ```

3. Are participation keys registered?
   ```bash
   sudo -u algorand goal account listpartkeys
   ```

### Permission Denied Errors

If you see permission errors:

1. Ensure the script is executable:
   ```bash
   chmod +x heartbeat.sh
   ```

2. Check sudo permissions for `goal` commands:
   ```bash
   sudo -u algorand goal node status
   ```

3. Verify the user in `heartbeat.service` has proper permissions

### Timer Not Running

```bash
# Check timer status
sudo systemctl status heartbeat.timer

# Check if timer is enabled
systemctl is-enabled heartbeat.timer

# Manually trigger a run
sudo systemctl start heartbeat.service
```

### Network Issues

The script includes automatic retry logic. If you see persistent network errors:

1. Check internet connectivity
2. Verify Healthchecks.io URL is correct
3. Check firewall rules
4. Review logs: `sudo journalctl -u heartbeat.service`

## How It Works

1. **Health Checks**: Script verifies node is running, synced, and has participation keys
2. **Stats Collection**: Gathers node status, system resources, and health metrics
3. **Conditional Heartbeat**: Only sends heartbeat if all checks pass
4. **Reliable Delivery**: Uses curl with retry logic and timeouts per Healthchecks.io recommendations

## Contributing

Contributions welcome! Feel free to:
- Report issues
- Suggest improvements
- Submit pull requests

## License

This script is provided as-is for the Algorand community. Use at your own risk.

## Support

For issues or questions:
- Open an issue on GitHub
- Check Healthchecks.io documentation: https://healthchecks.io/docs/

---

**Made for the Algorand community by Algorand node operators** 🚀

**Node Staking**: Stake with [SolarStake](https://app.nf.domains/name/solarstake.algo) on Valar and Reti networks.
