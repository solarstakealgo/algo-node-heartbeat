#!/bin/bash
#
# Algorand Node Heartbeat Script
# Sends a heartbeat to healthchecks.io only if all checks pass
#
# This script follows healthchecks.io best practices:
# - Uses POST requests to send stats in the request body
# - Implements retry logic for transient network failures
# - Sets appropriate timeouts to prevent hanging requests
# See https://healthchecks.io/docs/reliability_tips/ for more details
#

set -euo pipefail

# Step 1: Configuration
HEARTBEAT_URL="${HEARTBEAT_URL:-https://hc-ping.com/YOUR-UUID-HERE}"
ALGORAND_DATA="/var/lib/algorand"

# Step 2: Check if Algorand service is running
if ! systemctl is-active --quiet algorand.service; then
    exit 0  # Skip heartbeat
fi

# Step 2a: Check Valar and Reti staking services (optional - only if services exist)
VALAR_STATUS="not configured"
RETI_STATUS="not configured"
FAILURE_REASONS=""
STAKING_SERVICES_ENABLED=false

# Check Valar service (only if it exists)
if systemctl list-unit-files valar-daemon.service >/dev/null 2>&1; then
    STAKING_SERVICES_ENABLED=true
    if ! systemctl is-active --quiet valar-daemon.service; then
        VALAR_STATUS="DOWN"
        FAILURE_REASONS="${FAILURE_REASONS}Valar service is not running. "
    else
        # Get Valar uptime
        VALAR_UPTIME=$(systemctl show valar-daemon.service --property=ActiveEnterTimestamp --value 2>/dev/null | xargs -I {} date -d {} +%s 2>/dev/null)
        if [ -n "$VALAR_UPTIME" ]; then
            CURRENT_TIME=$(date +%s)
            UPTIME_SEC=$((CURRENT_TIME - VALAR_UPTIME))
            UPTIME_DAYS=$((UPTIME_SEC / 86400))
            UPTIME_HOURS=$(((UPTIME_SEC % 86400) / 3600))
            VALAR_STATUS="active (${UPTIME_DAYS}d ${UPTIME_HOURS}h)"
        else
            VALAR_STATUS="active"
        fi
    fi
fi

# Check Reti service (only if it exists)
if systemctl list-unit-files reti.service >/dev/null 2>&1; then
    STAKING_SERVICES_ENABLED=true
    if ! systemctl is-active --quiet reti.service; then
        RETI_STATUS="DOWN"
        FAILURE_REASONS="${FAILURE_REASONS}Reti service is not running. "
    else
        # Get Reti uptime
        RETI_UPTIME=$(systemctl show reti.service --property=ActiveEnterTimestamp --value 2>/dev/null | xargs -I {} date -d {} +%s 2>/dev/null)
        if [ -n "$RETI_UPTIME" ]; then
            CURRENT_TIME=$(date +%s)
            UPTIME_SEC=$((CURRENT_TIME - RETI_UPTIME))
            UPTIME_DAYS=$((UPTIME_SEC / 86400))
            UPTIME_HOURS=$(((UPTIME_SEC % 86400) / 3600))
            RETI_STATUS="active (${UPTIME_DAYS}d ${UPTIME_HOURS}h)"
        else
            RETI_STATUS="active"
        fi
    fi
fi

# If staking services are configured and either is down, send failure signal to Healthchecks.io
if [ "$STAKING_SERVICES_ENABLED" = "true" ]; then
    if [[ "$VALAR_STATUS" == "DOWN"* ]] || [[ "$RETI_STATUS" == "DOWN"* ]]; then
        FAILURE_MSG="Staking Services DOWN: ${FAILURE_REASONS}"
        curl -fsS -m 10 --retry 5 -o /dev/null \
          -X POST \
          -H "Content-Type: text/plain" \
          -d "${FAILURE_MSG}" \
          "${HEARTBEAT_URL}/fail"
        exit 1
    fi
fi

# Step 3: Check if node is synced and collect stats
NODE_STATUS=$(sudo -u algorand ALGORAND_DATA="$ALGORAND_DATA" goal node status)
LAST_BLOCK_TIME=$(echo "$NODE_STATUS" | grep "Time since last block" | awk '{print $5}')
SYNCED=$(awk -v t="$LAST_BLOCK_TIME" 'BEGIN {if (t < 30) print "1"; else print "0"}')
if [ "$SYNCED" = "0" ]; then
    exit 0  # Skip heartbeat
fi

# Collect additional Algorand stats (handle missing fields gracefully)
LAST_ROUND=$(echo "$NODE_STATUS" | grep "Last committed block:" | awk '{print $4}' 2>/dev/null || true)
LAST_ROUND=${LAST_ROUND:-"N/A"}
SYNC_TIME=$(echo "$NODE_STATUS" | grep "Sync time:" | awk '{print $3}' 2>/dev/null || true)
SYNC_TIME=${SYNC_TIME:-"N/A"}
CATCHUP_TIME=$(echo "$NODE_STATUS" | grep "Catchup time:" | awk '{print $3}' 2>/dev/null || true)
CATCHUP_TIME=${CATCHUP_TIME:-"N/A"}

# Collect system resource stats
# CPU usage - use vmstat for quick snapshot, or fallback to /proc/stat
if command -v vmstat >/dev/null 2>&1; then
    CPU_USAGE=$(vmstat 1 2 | tail -1 | awk '{printf "%.1f", 100-$15}' 2>/dev/null || echo "N/A")
else
    CPU_USAGE=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$3+$4+$5)} END {printf "%.1f", usage}' 2>/dev/null || echo "N/A")
fi
MEM_USAGE=$(free | grep Mem | awk '{printf "%.1f", ($3/$2) * 100.0}' 2>/dev/null || echo "N/A")
MEM_AVAIL=$(free -h | grep Mem | awk '{print $7}' 2>/dev/null || echo "N/A")

# Check disk usage for Algorand data directory
DISK_USAGE=$(df -h "$ALGORAND_DATA" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "N/A")
DISK_AVAIL=$(df -h "$ALGORAND_DATA" 2>/dev/null | tail -1 | awk '{print $4}' || echo "N/A")

# Check journal health (disk usage and recent errors)
JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | awk '{print $1}' || echo "N/A")
JOURNAL_ERRORS=$(journalctl -p err --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "^" || echo "0")

# Algorand service uptime
ALGORAND_UPTIME=$(systemctl show algorand.service --property=ActiveEnterTimestamp --value 2>/dev/null | xargs -I {} date -d {} +%s 2>/dev/null)
if [ -n "$ALGORAND_UPTIME" ]; then
    CURRENT_TIME=$(date +%s)
    UPTIME_SEC=$((CURRENT_TIME - ALGORAND_UPTIME))
    UPTIME_DAYS=$((UPTIME_SEC / 86400))
    UPTIME_HOURS=$(((UPTIME_SEC % 86400) / 3600))
    ALGORAND_UPTIME_STR="${UPTIME_DAYS}d ${UPTIME_HOURS}h"
else
    ALGORAND_UPTIME_STR="N/A"
fi

# System load average
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//' 2>/dev/null || echo "N/A")

# Step 4: Check for registered participation keys
PARTKEY_INFO=$(sudo -u algorand ALGORAND_DATA="$ALGORAND_DATA" goal account listpartkeys)
PARTKEY_COUNT=$(echo "$PARTKEY_INFO" | grep -c "yes")
if [ "$PARTKEY_COUNT" -eq 0 ]; then
    exit 0  # Skip heartbeat
fi

# Step 5: Prepare stats message
if [ "$STAKING_SERVICES_ENABLED" = "true" ]; then
    STATS=$(cat <<EOF
=== Algorand Node Status ===
Node Status: OK
Last Block Time: ${LAST_BLOCK_TIME}s ago
Last Round: ${LAST_ROUND}
Sync Time: ${SYNC_TIME}
Catchup Time: ${CATCHUP_TIME}
Active Participation Keys: ${PARTKEY_COUNT}
Service Uptime: ${ALGORAND_UPTIME_STR}

=== Staking Services ===
Valar: ${VALAR_STATUS}
Reti: ${RETI_STATUS}

=== System Resources ===
CPU Usage: ${CPU_USAGE}%
Memory Usage: ${MEM_USAGE}%
Memory Available: ${MEM_AVAIL}
Load Average: ${LOAD_AVG}
Disk Usage (${ALGORAND_DATA}): ${DISK_USAGE}%
Disk Available: ${DISK_AVAIL}

=== System Health ===
Journal Size: ${JOURNAL_SIZE}
Journal Errors (last 5min): ${JOURNAL_ERRORS}
EOF
)
else
    STATS=$(cat <<EOF
=== Algorand Node Status ===
Node Status: OK
Last Block Time: ${LAST_BLOCK_TIME}s ago
Last Round: ${LAST_ROUND}
Sync Time: ${SYNC_TIME}
Catchup Time: ${CATCHUP_TIME}
Active Participation Keys: ${PARTKEY_COUNT}
Service Uptime: ${ALGORAND_UPTIME_STR}

=== System Resources ===
CPU Usage: ${CPU_USAGE}%
Memory Usage: ${MEM_USAGE}%
Memory Available: ${MEM_AVAIL}
Load Average: ${LOAD_AVG}
Disk Usage (${ALGORAND_DATA}): ${DISK_USAGE}%
Disk Available: ${DISK_AVAIL}

=== System Health ===
Journal Size: ${JOURNAL_SIZE}
Journal Errors (last 5min): ${JOURNAL_ERRORS}
EOF
)
fi

# Step 6: Send heartbeat with stats (if all checks passed)
# Using healthchecks.io recommended curl options: -fsS -m 10 --retry 5
# -f: fail silently on server errors
# -s: silent mode (hide progress meter)
# -S: show errors even in silent mode
# -m 10: 10 second timeout
# --retry 5: retry up to 5 times on transient errors
# -o /dev/null: discard response body
curl -fsS -m 10 --retry 5 -o /dev/null \
  -X POST \
  -H "Content-Type: text/plain" \
  -d "${STATS}" \
  "${HEARTBEAT_URL}"

