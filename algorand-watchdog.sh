#!/bin/bash

set -euo pipefail

ALGOD_SERVICE="${ALGOD_SERVICE:-algorand.service}"
ALGOD_USER="${ALGOD_USER:-algorand}"
ALGORAND_DATA="${ALGORAND_DATA:-/var/lib/algorand}"
GOAL_TIMEOUT_SECONDS="${GOAL_TIMEOUT_SECONDS:-10}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
STALE_ROUND_SECONDS="${STALE_ROUND_SECONDS:-90}"
RECOVERY_COOLDOWN_SECONDS="${RECOVERY_COOLDOWN_SECONDS:-600}"
STATE_DIR="${STATE_DIR:-/run/algorand-watchdog}"
INCIDENT_DIR="${INCIDENT_DIR:-/var/log/algorand-watchdog}"
MAX_INCIDENTS="${MAX_INCIDENTS:-10}"
PROFILER_TIMEOUT_SECONDS="${PROFILER_TIMEOUT_SECONDS:-10}"

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
    exit 0
fi

log() {
    echo "algorand-watchdog: $*"
}

read_number() {
    local file="$1"
    local fallback="${2:-0}"
    local value

    if [[ -r "$file" ]]; then
        read -r value < "$file" || true
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$fallback"
}

read_systemd_value() {
    local property="$1"

    systemctl show "$ALGOD_SERVICE" --property="$property" --value 2>/dev/null || true
}

write_number() {
    local file="$1"
    local value="$2"
    printf '%s\n' "$value" > "$file"
}

increment_failure() {
    local name="$1"
    local file="$STATE_DIR/${name}.failures"
    local count

    count=$(read_number "$file")
    count=$((count + 1))
    write_number "$file" "$count"
    echo "$count"
}

reset_failure() {
    write_number "$STATE_DIR/$1.failures" 0
}

run_goal() {
    timeout --foreground --signal=TERM --kill-after=2s \
        "${GOAL_TIMEOUT_SECONDS}s" \
        sudo -u "$ALGOD_USER" env ALGORAND_DATA="$ALGORAND_DATA" goal "$@"
}

prune_incidents() {
    local -a incidents
    local remove_count old

    [[ "$MAX_INCIDENTS" =~ ^[1-9][0-9]*$ ]] || return 0
    incidents=()
    while IFS= read -r old; do
        incidents[${#incidents[@]}]="$old"
    done < <(
        find "$INCIDENT_DIR" -mindepth 1 -maxdepth 1 -type d \
            -name 'incident-*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -n | awk '{print $2}'
    )
    remove_count=$((${#incidents[@]} - MAX_INCIDENTS))
    (( remove_count > 0 )) || return 0

    for old in "${incidents[@]:0:remove_count}"; do
        [[ "$old" == "$INCIDENT_DIR"/incident-* ]] || continue
        rm -rf -- "$old"
    done
}

capture_profiler() {
    local destination="$1"
    local net token

    command -v curl >/dev/null 2>&1 || return
    [[ -r "$ALGORAND_DATA/algod.net" ]] || return
    [[ -r "$ALGORAND_DATA/algod.admin.token" ]] || return

    net=$(tr -d '\r\n' < "$ALGORAND_DATA/algod.net")
    case "$net" in
        localhost:*|127.0.0.1:*|'[::1]':*) ;;
        *)
            printf 'Profiler capture skipped: algod is not bound to loopback\n' \
                > "$destination.error"
            return
            ;;
    esac

    token=$(<"$ALGORAND_DATA/algod.admin.token")
    if ! curl --fail --silent --show-error \
        --max-time "$PROFILER_TIMEOUT_SECONDS" \
        --header "X-Algo-API-Token: $token" \
        "http://$net/debug/pprof/goroutine?debug=2" \
        > "$destination" 2> "$destination.error"; then
        rm -f -- "$destination"
    fi
    unset token
}

capture_diagnostics() {
    local reason="$1"
    local pid incident timestamp task tid artifact

    pid=$(read_systemd_value MainPID)
    log "capturing incident evidence: $reason; main_pid=${pid:-unknown}"

    umask 077
    if [[ "$INCIDENT_DIR" != /* ]] || [[ "$INCIDENT_DIR" == "/" ]]; then
        log "incident directory is unsafe; skipping extended capture: $INCIDENT_DIR"
        return
    fi
    install -d -m 0700 "$INCIDENT_DIR"
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    incident=$(mktemp -d "$INCIDENT_DIR/incident-$timestamp-$$-XXXXXX")
    chmod 0700 "$incident"

    {
        printf 'captured_utc=%s\n' "$timestamp"
        printf 'reason=%s\n' "$reason"
        printf 'algod_service=%s\n' "$ALGOD_SERVICE"
        printf 'main_pid=%s\n' "${pid:-unknown}"
    } > "$incident/summary.txt"

    if command -v algod >/dev/null 2>&1; then
        algod -v > "$incident/algod-version.txt" 2>&1 || true
    fi
    systemctl show "$ALGOD_SERVICE" \
        -p ActiveState -p SubState -p Result -p MainPID -p NRestarts \
        -p ExecMainStartTimestamp -p ExecMainExitTimestamp \
        -p ExecMainCode -p ExecMainStatus -p MemoryCurrent -p MemoryPeak \
        -p TasksCurrent -p CPUUsageNSec \
        > "$incident/systemd-state.txt" 2>&1 || true
    capture_profiler "$incident/goroutines.txt"

    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/status" ]]; then
        log "process state: $(awk '/^(State|VmRSS|VmSwap|Threads):/ {printf "%s=%s ", $1, $2}' "/proc/$pid/status")"
        cp "/proc/$pid/status" "$incident/process-status.txt" 2>/dev/null || true
        cp "/proc/$pid/limits" "$incident/process-limits.txt" 2>/dev/null || true
        cp "/proc/$pid/wchan" "$incident/process-wchan.txt" 2>/dev/null || true
        if [[ -r "/proc/$pid/wchan" ]]; then
            log "process wait channel: $(<"/proc/$pid/wchan")"
        fi

        {
            printf 'tid\tname\twait_channel\n'
            for task in /proc/"$pid"/task/*; do
                [[ -d "$task" ]] || continue
                tid=${task##*/}
                printf '%s\t' "$tid"
                tr -d '\n' < "$task/comm" 2>/dev/null || true
                printf '\t'
                tr -d '\n' < "$task/wchan" 2>/dev/null || true
                printf '\n'
            done
        } > "$incident/thread-waits.txt"

        command -v lsof >/dev/null 2>&1 \
            && lsof -nP -p "$pid" > "$incident/open-files.txt" 2>&1 || true
    fi

    if [[ -r "$ALGORAND_DATA/node.log" ]]; then
        log "recent algod warnings follow"
        tail -n 80 "$ALGORAND_DATA/node.log" \
            | grep -E 'level":"(warning|error)|too long since our ledger advanced|no peer pools available' \
            | tail -n 20 || true
        tail -n 500 "$ALGORAND_DATA/node.log" > "$incident/node-log-tail.txt" || true
    fi

    journalctl -u "$ALGOD_SERVICE" --since '-10 minutes' --no-pager \
        > "$incident/algod-journal.txt" 2>&1 || true
    journalctl -u algorand-watchdog.service --since '-10 minutes' --no-pager \
        > "$incident/watchdog-journal.txt" 2>&1 || true
    grep -E 'goroutine |go-deadlock|deadlockLogger|panic:|participationRegistry|registeryDbOps|stateproof' \
        "$incident/algod-journal.txt" > "$incident/deadlock-signature.txt" 2>/dev/null || true
    systemctl list-timers algorand-watchdog.timer --no-pager \
        > "$incident/watchdog-timer.txt" 2>&1 || true

    {
        uname -a
        uptime
        printf 'captured_epoch=%s\n' "$(date +%s)"
    } > "$incident/host-state.txt" 2>&1 || true

    if command -v jq >/dev/null 2>&1 && [[ -r "$ALGORAND_DATA/config.json" ]]; then
        jq '{
            DeadlockDetection,
            DeadlockDetectionThreshold,
            EnableProfiler,
            EnableP2PHybridMode,
            IncomingConnectionsLimit,
            MaxConnectionsPerIP,
            ParticipationKeysRefreshInterval
        }' "$ALGORAND_DATA/config.json" > "$incident/algod-config-whitelist.json" 2>&1 || true
    fi
    command -v ss >/dev/null 2>&1 \
        && ss -s > "$incident/socket-summary.txt" 2>&1 || true
    command -v lslocks >/dev/null 2>&1 \
        && lslocks > "$incident/file-locks.txt" 2>&1 || true
    free -h > "$incident/memory.txt" 2>&1 || true
    df -h "$ALGORAND_DATA" > "$incident/disk-space.txt" 2>&1 || true
    df -i "$ALGORAND_DATA" > "$incident/disk-inodes.txt" 2>&1 || true

    {
        printf '# Algod incident captured %s\n\n' "$timestamp"
        printf '## Summary\n\n'
        printf -- '- Trigger: `%s`\n' "$reason"
        printf -- '- Main PID at capture: `%s`\n' "${pid:-unknown}"
        printf -- '- Algod version: `%s`\n' \
            "$(head -n 1 "$incident/algod-version.txt" 2>/dev/null || printf unknown)"
        printf '\n## Evidence to include\n\n'
        printf -- '- `deadlock-signature.txt` (focused stack evidence)\n'
        printf -- '- `algod-journal.txt` (full bounded journal; review before attaching)\n'
        printf -- '- `systemd-state.txt` (exit and restart metadata)\n'
        printf -- '- `algod-config-whitelist.json` (relevant non-secret settings, when available)\n'
        printf -- '- `host-state.txt`, `memory.txt`, `disk-space.txt`, and `socket-summary.txt`\n'
        printf '\n## Focused stack excerpt\n\n```text\n'
        head -n 200 "$incident/deadlock-signature.txt" 2>/dev/null || true
        printf '```\n'
        printf '\n## Before posting publicly\n\n'
        printf 'Review all attachments and remove account addresses, participation IDs, hostnames, '
        printf 'public IP addresses, and any other operator-identifying data. API tokens are not captured.\n'
    } > "$incident/github-issue-draft.md"

    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "$incident"
            for artifact in *; do
                [[ "$artifact" == manifest.sha256 ]] && continue
                [[ -f "$artifact" ]] || continue
                sha256sum -- "$artifact"
            done
        ) > "$incident/manifest.sha256" 2>/dev/null || true
    fi

    prune_incidents
    log "diagnostic incident bundle saved at $incident"
}

capture_first_anomaly() {
    local failures="$1"
    local reason="$2"

    if (( failures == 1 )); then
        capture_diagnostics "first anomaly: $reason"
    fi
}

record_process_identity() {
    local current_pid current_restarts previous_pid previous_restarts reason

    current_pid=$(read_systemd_value MainPID)
    current_restarts=$(read_systemd_value NRestarts)
    previous_pid=$(read_number "$STATE_DIR/last_main_pid")
    previous_restarts=$(read_number "$STATE_DIR/last_nrestarts")

    # A first run establishes a baseline. A later PID or restart-counter change
    # means algod exited between watchdog checks, so preserve the preceding
    # journal even when the replacement process is already healthy.
    if [[ "$current_pid" =~ ^[1-9][0-9]*$ ]]; then
        if (( previous_pid > 0 && current_pid != previous_pid )); then
            reason="algod process changed from pid $previous_pid to $current_pid"
            if [[ "$current_restarts" =~ ^[0-9]+$ ]]; then
                reason+="; systemd restarts $previous_restarts to $current_restarts"
            fi
            capture_diagnostics "$reason"
        elif [[ "$current_restarts" =~ ^[0-9]+$ ]] \
            && (( previous_pid > 0 && current_restarts > previous_restarts )); then
            capture_diagnostics \
                "algod systemd restart counter increased from $previous_restarts to $current_restarts"
        fi

        write_number "$STATE_DIR/last_main_pid" "$current_pid"
        if [[ "$current_restarts" =~ ^[0-9]+$ ]]; then
            write_number "$STATE_DIR/last_nrestarts" "$current_restarts"
        fi
    fi
}

recover_algod() {
    local reason="$1"
    local now last_recovery old_pid new_pid

    now=$(date +%s)
    last_recovery=$(read_number "$STATE_DIR/last_recovery")
    if (( now - last_recovery < RECOVERY_COOLDOWN_SECONDS )); then
        log "recovery suppressed by ${RECOVERY_COOLDOWN_SECONDS}s cooldown: $reason"
        return
    fi

    capture_diagnostics "$reason"
    write_number "$STATE_DIR/last_recovery" "$now"
    old_pid=$(read_systemd_value MainPID)

    # Go prints all goroutine stacks on SIGQUIT and exits. The unit's
    # Restart=always policy then starts a clean process after RestartSec.
    if [[ "$old_pid" =~ ^[1-9][0-9]*$ ]]; then
        log "sending SIGQUIT to algod for a goroutine dump and automatic restart"
        systemctl kill --kill-who=main --signal=SIGQUIT "$ALGOD_SERVICE"
    else
        log "algod has no main PID; requesting a normal service restart"
        systemctl restart "$ALGOD_SERVICE"
    fi

    for _ in $(seq 1 20); do
        sleep 1
        new_pid=$(read_systemd_value MainPID)
        if systemctl is-active --quiet "$ALGOD_SERVICE" \
            && [[ "$new_pid" =~ ^[1-9][0-9]*$ ]] \
            && [[ "$new_pid" != "$old_pid" ]]; then
            log "algod recovered with main_pid=$new_pid"
            reset_failure status
            reset_failure partkeys
            reset_failure round
            return
        fi
    done

    log "SIGQUIT recovery did not complete within 20s; forcing a restart"
    systemctl kill --kill-who=all --signal=SIGKILL "$ALGOD_SERVICE" || true
    systemctl restart "$ALGOD_SERVICE"
}

# Count starts and completions separately: both can describe the same sync.
recent_catchups() {
    local file modified cutoff
    cutoff=$(( $(date +%s) - 120 ))
    for file in "$ALGORAND_DATA/node.archive.log" "$ALGORAND_DATA/node.log"; do
        [[ -r "$file" ]] || continue
        if [[ "$file" == */node.archive.log ]]; then
            modified=$(stat -c %Y "$file") || return 1
            (( modified >= cutoff )) || continue
        fi
        tail -c 25165824 "$file" || return 1
    done | python3 -c '
import datetime, json, sys
starts = stops = 0
cutoff = int(sys.argv[1])
for line in sys.stdin.buffer:
    if b"/CatchupStart" not in line and b"finished catching up, now at round" not in line:
        continue
    try:
        event = json.loads(line)
        stamp = datetime.datetime.fromisoformat(event["time"].replace("Z", "+00:00"))
        message = event["msg"]
    except (KeyError, ValueError, TypeError):
        continue  # The bounded tail may start inside a record.
    if stamp.timestamp() >= cutoff:
        starts += message.endswith("/CatchupStart")
        stops += message.startswith("Catchup Service: finished catching up, now at round ")
print(max(starts, stops))' "$cutoff"
}

check_network() {
    local peers count catchups reason="" failures marker="$STATE_DIR/network-degraded"
    if ! peers=$(run_goal node peers 2>/dev/null); then
        reason="peer query failed"
    elif ! count=$(awk '
        NR == 1 && $1 == "CONN" && $2 == "TYPE" && $3 == "NETWORK" { header=1; next }
        $1 == "inbound" || $1 == "outbound" { n++; next }
        NF { invalid=1 }
        END { if (!header || invalid) exit 1; print n+0 }' <<<"$peers"); then
        reason="peer query returned unrecognized output"
    elif (( count == 0 )); then
        reason="zero connected peers"
    fi

    if [[ ! -r "$ALGORAND_DATA/node.log" ]] || ! catchups=$(recent_catchups); then
        reason="${reason:+$reason; }catchup log unavailable"
    elif (( catchups >= 3 )); then
        reason="${reason:+$reason; }$catchups catchups in the last 120 seconds"
    fi

    if [[ -n "$reason" ]]; then
        reset_failure network_clear
        failures=$(increment_failure network)
        log "network warning at round $last_round: $reason"
        if (( failures >= FAILURE_THRESHOLD || ${catchups:-0} >= 3 )) && [[ ! -e "$marker" ]]; then
            touch "$marker"
            capture_diagnostics "network degraded at round $last_round: $reason"
        fi
        return 1
    fi

    reset_failure network
    if [[ -e "$marker" ]]; then
        failures=$(increment_failure network_clear)
        if (( failures < FAILURE_THRESHOLD )); then
            log "network recovering ($failures/$FAILURE_THRESHOLD)"
            return 1
        fi
        rm -f -- "$marker"
        log "network recovered at round $last_round; $count connected peers"
    fi
}

record_process_identity

if ! systemctl is-active --quiet "$ALGOD_SERVICE"; then
    failures=$(increment_failure status)
    log "$ALGOD_SERVICE is not active ($failures/$FAILURE_THRESHOLD)"
    capture_first_anomaly "$failures" "$ALGOD_SERVICE is not active"
    if (( failures >= FAILURE_THRESHOLD )); then
        recover_algod "$ALGOD_SERVICE remained inactive for $failures checks"
    fi
    exit 0
fi

if ! node_status=$(run_goal node status 2>&1); then
    failures=$(increment_failure status)
    log "node status failed or timed out ($failures/$FAILURE_THRESHOLD)"
    capture_first_anomaly "$failures" "node status failed or timed out"
    if (( failures >= FAILURE_THRESHOLD )); then
        recover_algod "node status failed $failures consecutive times"
    fi
    exit 0
fi
reset_failure status

last_round=$(awk '/Last committed block:/ {print $4; exit}' <<<"$node_status")
last_block_time=$(awk '/Time since last block:/ {print $5; exit}' <<<"$node_status")
last_block_time=${last_block_time%s}
previous_round=$(read_number "$STATE_DIR/last_round")

if [[ "$last_round" =~ ^[0-9]+$ ]]; then
    write_number "$STATE_DIR/last_round" "$last_round"
fi

if [[ "$last_round" =~ ^[0-9]+$ ]] \
    && [[ "$last_block_time" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    && [[ "$last_round" == "$previous_round" ]] \
    && awk -v age="$last_block_time" -v limit="$STALE_ROUND_SECONDS" \
        'BEGIN { exit !(age >= limit) }'; then
    failures=$(increment_failure round)
    log "round $last_round is stale (${last_block_time}s, $failures/$FAILURE_THRESHOLD)"
    capture_first_anomaly "$failures" \
        "round $last_round is stale at ${last_block_time}s"
    if (( failures >= FAILURE_THRESHOLD )); then
        recover_algod "round $last_round remained stale for $failures checks"
        exit 0
    fi
else
    reset_failure round
fi

if ! run_goal account listpartkeys >/dev/null 2>&1; then
    failures=$(increment_failure partkeys)
    log "participation-key query failed or timed out ($failures/$FAILURE_THRESHOLD)"
    capture_first_anomaly "$failures" "participation-key query failed or timed out"
    if (( failures >= FAILURE_THRESHOLD )); then
        recover_algod "participation-key query failed $failures consecutive times"
    fi
    exit 0
fi
reset_failure partkeys

check_network || exit 0

log "healthy at round $last_round; participation-key query responsive"
