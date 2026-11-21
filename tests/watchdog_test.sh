#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
MOCK_BIN="$TEST_DIR/bin"
MOCK_LOG="$TEST_DIR/systemctl.log"
MOCK_PID_FILE="$TEST_DIR/pid"
MOCK_RESTARTS_FILE="$TEST_DIR/restarts"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$MOCK_BIN" "$TEST_DIR/data" "$TEST_DIR/incidents"
echo 111 > "$MOCK_PID_FILE"
echo 0 > "$MOCK_RESTARTS_FILE"
echo '127.0.0.1:8080' > "$TEST_DIR/data/algod.net"
echo 'test-token' > "$TEST_DIR/data/algod.admin.token"
echo '{"level":"warning","msg":"test warning"}' > "$TEST_DIR/data/node.log"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
    is-active)
        exit 0
        ;;
    show)
        case "$*" in
            *MainPID*--value*) cat "$MOCK_PID_FILE" ;;
            *NRestarts*--value*) cat "$MOCK_RESTARTS_FILE" ;;
            *) echo "ActiveState=active"; echo "MainPID=$(cat "$MOCK_PID_FILE")"; echo "NRestarts=$(cat "$MOCK_RESTARTS_FILE")" ;;
        esac
        ;;
    kill)
        printf 'kill %s\n' "$*" >> "$MOCK_LOG"
        echo 222 > "$MOCK_PID_FILE"
        echo $(( $(cat "$MOCK_RESTARTS_FILE") + 1 )) > "$MOCK_RESTARTS_FILE"
        ;;
    restart)
        printf 'restart %s\n' "$*" >> "$MOCK_LOG"
        echo 222 > "$MOCK_PID_FILE"
        echo $(( $(cat "$MOCK_RESTARTS_FILE") + 1 )) > "$MOCK_RESTARTS_FILE"
        ;;
esac
EOF

cat > "$MOCK_BIN/flock" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$MOCK_BIN/sudo" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-u" ]]; then
    shift 2
fi
exec "$@"
EOF

cat > "$MOCK_BIN/timeout" <<'EOF'
#!/bin/bash
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
EOF

cat > "$MOCK_BIN/goal" <<'EOF'
#!/bin/bash
if [[ "$*" == "node peers" ]]; then
    echo "CONN TYPE  NETWORK  ADDRESS"
    [[ "${MOCK_PEERS:-yes}" == yes ]] && echo "outbound   ws       relay.example"
    exit 0
fi
if [[ "$*" == "node status" ]]; then
    [[ "${MOCK_STATUS_FAIL:-no}" == "yes" ]] && exit 1
    cat <<STATUS
Last committed block: ${MOCK_ROUND:-123456}
Time since last block: ${MOCK_BLOCK_AGE:-2.0}s
STATUS
    exit 0
fi
if [[ "$*" == "account listpartkeys" ]]; then
    [[ "${MOCK_PARTKEY_FAIL:-no}" == "yes" ]] && exit 1
    echo "yes ABC DEF"
    exit 0
fi
exit 1
EOF

for command in lsof ss lslocks free df uname uptime sha256sum; do
    cat > "$MOCK_BIN/$command" <<'EOF'
#!/bin/bash
echo "mock diagnostic output"
EOF
done

cat > "$MOCK_BIN/journalctl" <<'EOF'
#!/bin/bash
cat <<JOURNAL
algod: panic: Potential deadlock detected
algod: github.com/algorand/go-algorand/data/account.(*participationDB).DeleteStateProofKeys
algod: github.com/algorand/go-algorand/data/account/participationRegistry.go:433
JOURNAL
EOF

cat > "$MOCK_BIN/jq" <<'EOF'
#!/bin/bash
echo '{"DeadlockDetection":1,"DeadlockDetectionThreshold":60}'
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/bash
echo "goroutine 1 [running]:"
echo "mock.stack()"
EOF

cat > "$MOCK_BIN/algod" <<'EOF'
#!/bin/bash
echo "5.0.2.stable"
EOF

chmod +x "$MOCK_BIN"/*

run_watchdog() {
    local state_dir="$1"
    PATH="$MOCK_BIN:$PATH" \
    MOCK_LOG="$MOCK_LOG" \
    MOCK_PID_FILE="$MOCK_PID_FILE" \
    MOCK_RESTARTS_FILE="$MOCK_RESTARTS_FILE" \
    MOCK_STATUS_FAIL="${MOCK_STATUS_FAIL:-no}" \
    MOCK_PARTKEY_FAIL="${MOCK_PARTKEY_FAIL:-no}" \
    MOCK_ROUND="${MOCK_ROUND:-123456}" \
    MOCK_BLOCK_AGE="${MOCK_BLOCK_AGE:-2.0}" \
    STATE_DIR="$state_dir" \
    INCIDENT_DIR="$TEST_DIR/incidents" \
    MAX_INCIDENTS=10 \
    ALGORAND_DATA="$TEST_DIR/data" \
    FAILURE_THRESHOLD=3 \
    RECOVERY_COOLDOWN_SECONDS=600 \
    "$REPO_DIR/algorand-watchdog.sh"
}

STATE_ONE="$TEST_DIR/state-one"
: > "$MOCK_LOG"
run_watchdog "$STATE_ONE" >/dev/null
[[ ! -s "$MOCK_LOG" ]]

incident_count=$(find "$TEST_DIR/incidents" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
MOCK_PARTKEY_FAIL=yes run_watchdog "$STATE_ONE" >/dev/null
[[ $(find "$TEST_DIR/incidents" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') -eq $((incident_count + 1)) ]]
grep -R -q 'first anomaly: participation-key query failed or timed out' "$TEST_DIR/incidents"
grep -R -q 'participationRegistry.go:433' "$TEST_DIR/incidents"
grep -R -q '## Evidence to include' "$TEST_DIR/incidents"
MOCK_PARTKEY_FAIL=yes run_watchdog "$STATE_ONE" >/dev/null
MOCK_PARTKEY_FAIL=yes run_watchdog "$STATE_ONE" >/dev/null
[[ $(grep -c '^kill ' "$MOCK_LOG") -eq 1 ]]
[[ -n $(find "$TEST_DIR/incidents" -name goroutines.txt -type f -print -quit) ]]
grep -R -q 'mock.stack' "$TEST_DIR/incidents"
! grep -R -q 'test-token' "$TEST_DIR/incidents"

MOCK_STATUS_FAIL=yes run_watchdog "$STATE_ONE" >/dev/null
MOCK_STATUS_FAIL=yes run_watchdog "$STATE_ONE" >/dev/null
MOCK_STATUS_FAIL=yes run_watchdog "$STATE_ONE" >/dev/null
[[ $(grep -c '^kill ' "$MOCK_LOG") -eq 1 ]]

STATE_TWO="$TEST_DIR/state-two"
: > "$MOCK_LOG"
echo 111 > "$MOCK_PID_FILE"
echo 0 > "$MOCK_RESTARTS_FILE"
MOCK_BLOCK_AGE=120 run_watchdog "$STATE_TWO" >/dev/null
MOCK_BLOCK_AGE=120 run_watchdog "$STATE_TWO" >/dev/null
MOCK_BLOCK_AGE=120 run_watchdog "$STATE_TWO" >/dev/null
MOCK_BLOCK_AGE=120 run_watchdog "$STATE_TWO" >/dev/null
[[ $(grep -c '^kill ' "$MOCK_LOG") -eq 1 ]]

STATE_THREE="$TEST_DIR/state-three"
: > "$MOCK_LOG"
echo 333 > "$MOCK_PID_FILE"
echo 4 > "$MOCK_RESTARTS_FILE"
run_watchdog "$STATE_THREE" >/dev/null
echo 444 > "$MOCK_PID_FILE"
echo 5 > "$MOCK_RESTARTS_FILE"
run_watchdog "$STATE_THREE" >/dev/null
grep -R -q 'algod process changed from pid 333 to 444; systemd restarts 4 to 5' "$TEST_DIR/incidents"
[[ ! -s "$MOCK_LOG" ]]

STATE_NET="$TEST_DIR/state-network"
marker="$STATE_NET/network-degraded"
sample_time=$(date -u +%FT%TZ)
write_events() {
    local time="$1" round
    shift
    for round in "$@"; do
        printf '{"time":"%s","msg":"/ApplicationState/CatchupStart","round":%s}\n' "$time" "$round"
        printf '{"msg":"Catchup Service: finished catching up, now at round %s","time":"%s"}\n' "$round" "$time"
    done
}
write_events "2020-01-01T00:00:00Z" 1 2 3 > "$TEST_DIR/data/node.log"
write_events "$sample_time" 4 5 >> "$TEST_DIR/data/node.log"
run_watchdog "$STATE_NET" >/dev/null
[[ ! -e "$marker" ]]
mv "$TEST_DIR/data/node.log" "$TEST_DIR/data/node.archive.log"
write_events "$sample_time" 6 > "$TEST_DIR/data/node.log"
MOCK_ROUND=123457 run_watchdog "$STATE_NET" >/dev/null
[[ -e "$marker" ]]
MOCK_ROUND=123458 run_watchdog "$STATE_NET" >/dev/null
[[ $(grep -l 'network degraded.*3 catchups' "$TEST_DIR"/incidents/*/summary.txt | wc -l) -eq 1 ]]
: > "$TEST_DIR/data/node.log"
: > "$TEST_DIR/data/node.archive.log"
for _ in 1 2; do run_watchdog "$STATE_NET" >/dev/null; done
[[ -e "$marker" ]]
run_watchdog "$STATE_NET" >/dev/null
[[ ! -e "$marker" ]]
for round in 123459 123460; do MOCK_PEERS=no MOCK_ROUND="$round" run_watchdog "$STATE_NET" >/dev/null; done
[[ ! -e "$marker" ]]
MOCK_PEERS=no MOCK_ROUND=123461 run_watchdog "$STATE_NET" >/dev/null
[[ -e "$marker" && ! -s "$MOCK_LOG" ]]
echo "watchdog tests passed"
