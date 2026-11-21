# Algo Node Heartbeat

A robust heartbeat monitoring script for Algorand nodes that sends health status to [Healthchecks.io](https://healthchecks.io/). The script only sends heartbeats when your node passes all health checks, ensuring you only get alerts when something is actually wrong.

## Features

- ✅ **Smart Health Checks**: Only sends heartbeat when node is healthy
  - Verifies Algorand service is running
  - Confirms node is synced (last block < 30 seconds ago)
  - Validates participation keys are registered
  - **Optional: Monitors Valar and Reti staking services** - Automatically detects if services are configured and sends DOWN alert if either is not running (gracefully skips if not installed)
- 📊 **Comprehensive Stats**: Sends detailed node and system metrics
  - Node status (last block time, round, sync/catchup times)
  - Staking services status (Valar and Reti) - only included if services are configured
  - System resources (CPU, memory, disk usage)
  - Service uptime and system load
  - Journal health monitoring
- 🔄 **Reliable Delivery**: Follows Healthchecks.io best practices
  - Automatic retry on transient failures
  - Bounded `goal` and delivery calls so a stuck algod API cannot trap the timer
  - Error handling and logging
- 🛠️ **Deadlock Recovery**: Optional external watchdog
  - Requires three consecutive failures before acting
  - Detects stuck status, participation-key queries, and stale rounds
  - Captures a private incident bundle at the first anomaly and before recovery
  - Detects an algod PID or systemd restart-counter change and preserves the
    preceding crash journal even when the new process is already healthy
  - Captures a Go goroutine dump before watchdog-initiated recovery
  - Enforces a ten-minute recovery cooldown to prevent restart loops

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

To install automatic deadlock recovery as well:

```bash
sudo install -o root -g root -m 0755 algorand-watchdog.sh /usr/local/sbin/algorand-watchdog.sh
sudo cp algorand-watchdog.service /etc/systemd/system/
sudo cp algorand-watchdog.timer /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/algorand.service.d
sudo cp algorand-watchdog.conf /etc/systemd/system/algorand.service.d/10-watchdog.conf
```

The drop-in limits a deadlocked algod shutdown to 20 seconds and disables large
core files. The watchdog itself sends `SIGQUIT` only after three consecutive
failures; Go writes goroutine stacks to the journal and systemd's existing
`Restart=always` policy starts a clean process.

For root-cause diagnostics on a loopback-only algod API, enable the built-in
deadlock detector and profiler before restarting algod:

```bash
sudo algocfg set -d /var/lib/algorand -p DeadlockDetection -v 1
sudo algocfg set -d /var/lib/algorand -p DeadlockDetectionThreshold -v 60
sudo algocfg set -d /var/lib/algorand -p EnableProfiler -v true
```

The detector records all goroutine stacks and terminates algod when a lock is
held beyond the threshold; systemd then restarts it. Profiler endpoints should
not be enabled when the algod API is exposed to untrusted clients.

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
sudo systemctl enable --now algorand-watchdog.timer

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

The script behavior:
- **Sends DOWN alert** if Valar or Reti staking services are configured but not running (automatically detects if services exist)
- **Skips heartbeat** (no alert) if:
  - Algorand service is not running
  - Last block time > 30 seconds (node not synced)
  - No participation keys registered

**Note**: Valar and Reti monitoring is **optional**. The script automatically detects if these services are installed. If they're not configured, the script works normally without them - perfect for nodes that don't run staking services!

To adjust the sync threshold, edit line 25 in `heartbeat.sh`:

```bash
SYNCED=$(awk -v t="$LAST_BLOCK_TIME" 'BEGIN {if (t < 30) print "1"; else print "0"}')
# Change 30 to your desired threshold (in seconds)
```

### Watchdog thresholds

The watchdog runs every 30 seconds and recovers algod after three consecutive
failures (about 90 seconds). Defaults can be overridden in
`algorand-watchdog.service` with environment variables:

```ini
[Service]
Environment="GOAL_TIMEOUT_SECONDS=10"
Environment="FAILURE_THRESHOLD=3"
Environment="STALE_ROUND_SECONDS=90"
Environment="RECOVERY_COOLDOWN_SECONDS=600"
Environment="INCIDENT_DIR=/var/log/algorand-watchdog"
Environment="MAX_INCIDENTS=10"
```

The network check requires Python 3.11+ and a `goal` with `node peers`.
Three consecutive zero-peer or failed peer checks, or at least three distinct
catchup cycles in a rolling 120-second window, flag degraded networking even
while rounds advance. The watchdog counts starts and finishes separately in
bounded 24 MiB tails of the current algod JSON log and a recently rotated
archive. At very high log rates this can undercount. An unreadable current log
also counts as a failed check. Keep info-level catchup logging enabled.

Network degradation creates one incident bundle per episode and places
`network-degraded` in the watchdog state directory. The normal heartbeat
skips success delivery while the marker exists, so the existing Healthchecks.io
missed-ping alert fires after its configured grace period. Three clean checks
clear it. Network warnings alone never restart algod. When overriding
`STATE_DIR`, set `WATCHDOG_NETWORK_MARKER` in the heartbeat service to the
matching path and allow its user to traverse the directory. If permanently
disabling the watchdog, remove its marker after verifying recovery.

A participation-key timeout alone is not enough to restart algod. It must recur
for three checks, but the first timeout immediately creates an evidence bundle.
Recovery events and goroutine dumps are available with:

```bash
sudo journalctl -u algorand-watchdog.service -u algorand.service
```

Extended evidence from the ten most recent anomalies, unexpected restarts, and
recoveries is stored in private, root-readable timestamped directories under
`/var/log/algorand-watchdog`. Each bundle includes a profiler goroutine snapshot
when available, the algod and watchdog journals, an extracted deadlock signature,
per-thread wait channels, systemd exit/restart metadata, a whitelist of relevant
algod settings, open files, resource state, recent algod logs, and a SHA-256
manifest. A `github-issue-draft.md` file identifies the exact evidence to include
and the operator-identifying fields to review before posting publicly.
Authentication tokens and the complete algod configuration are never written to
the bundle.

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
   sudo -u algorand timeout 10s goal account listpartkeys
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
