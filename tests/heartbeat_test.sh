#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
MOCK_BIN="$TEST_DIR/bin"
MOCK_LOG="$TEST_DIR/curl.log"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$MOCK_BIN" "$TEST_DIR/data"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/bin/bash
if [[ "$1" == "is-active" ]]; then
    service="${*: -1}"
    if [[ "$service" == "valar-daemon.service" && "${MOCK_VALAR_STATUS:-active}" != "active" ]]; then
        exit 3
    fi
    if [[ "$service" == "reti.service" && "${MOCK_RETI_STATUS:-active}" != "active" ]]; then
        exit 3
    fi
    exit 0
fi
if [[ "$1" == "list-unit-files" ]]; then
    service="$2"
    if [[ "${MOCK_STAKING_CONFIGURED:-yes}" == "yes" ]]; then
        printf '%s enabled\n' "$service"
        exit 0
    fi
    exit 1
fi
if [[ "$1" == "show" ]]; then
    echo "2026-09-29 00:00:00 UTC"
    exit 0
fi
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
if [[ "${MOCK_TIMEOUT_TARGET:-}" == "partkeys" && "$*" == *"account listpartkeys"* ]]; then
    exit 124
fi
exec "$@"
EOF

cat > "$MOCK_BIN/goal" <<'EOF'
#!/bin/bash
if [[ "$*" == "node status" ]]; then
    age="2.0"
    [[ "${MOCK_NODE_MODE:-healthy}" == "unsynced" ]] && age="120.0"
    cat <<STATUS
Last committed block: 123456
Time since last block: ${age}s
Sync Time: 0.0s
STATUS
    exit 0
fi
if [[ "$*" == "account listpartkeys" ]]; then
    echo "Registered Account ParticipationID"
    [[ "${MOCK_PARTKEY_MODE:-active}" == "active" ]] && echo "yes ABC DEF"
    exit 0
fi
exit 1
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/bash
printf 'CALL %s\n' "${*: -1}" >> "$MOCK_LOG"
[[ "${MOCK_CURL_FAIL:-no}" == "yes" ]] && exit 22
exit 0
EOF

cat > "$MOCK_BIN/date" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-d" ]]; then
    echo 1790870400
else
    echo 1790874000
fi
EOF

cat > "$MOCK_BIN/vmstat" <<'EOF'
#!/bin/bash
echo "r b swpd free buff cache si so bi bo in cs us sy id wa st"
echo "0 0 0 0 0 0 0 0 0 0 0 0 5 3 92 0 0"
EOF

cat > "$MOCK_BIN/free" <<'EOF'
#!/bin/bash
echo "Mem: 1000 400 100 0 0 600"
EOF

chmod +x "$MOCK_BIN"/*

run_heartbeat() {
    : > "$MOCK_LOG"
    PATH="$MOCK_BIN:$PATH" \
    WATCHDOG_NETWORK_MARKER="$TEST_DIR/network-degraded" \
    MOCK_LOG="$MOCK_LOG" \
    MOCK_NODE_MODE="${MOCK_NODE_MODE:-healthy}" \
    MOCK_PARTKEY_MODE="${MOCK_PARTKEY_MODE:-active}" \
    MOCK_STAKING_CONFIGURED="${MOCK_STAKING_CONFIGURED:-yes}" \
    MOCK_VALAR_STATUS="${MOCK_VALAR_STATUS:-active}" \
    MOCK_RETI_STATUS="${MOCK_RETI_STATUS:-active}" \
    MOCK_CURL_FAIL="${MOCK_CURL_FAIL:-no}" \
    MOCK_TIMEOUT_TARGET="${MOCK_TIMEOUT_TARGET:-}" \
    ALGORAND_DATA="$TEST_DIR/data" \
    HEARTBEAT_URL="http://127.0.0.1/heartbeat" \
    "$REPO_DIR/heartbeat.sh"
}

assert_lines() {
    local expected="$1"
    local actual
    actual=$(wc -l < "$MOCK_LOG" | tr -d ' ')
    [[ "$actual" == "$expected" ]] || {
        echo "expected $expected curl calls, got $actual" >&2
        exit 1
    }
}

MOCK_NODE_MODE=healthy MOCK_PARTKEY_MODE=active \
MOCK_STAKING_CONFIGURED=yes MOCK_VALAR_STATUS=active MOCK_RETI_STATUS=active \
run_heartbeat
assert_lines 1

MOCK_NODE_MODE=unsynced run_heartbeat
assert_lines 0

MOCK_NODE_MODE=healthy MOCK_STAKING_CONFIGURED=no run_heartbeat
assert_lines 1

MOCK_STAKING_CONFIGURED=no MOCK_PARTKEY_MODE=none run_heartbeat
assert_lines 0

MOCK_STAKING_CONFIGURED=yes MOCK_VALAR_STATUS=inactive \
run_heartbeat && { echo "inactive Valar should fail" >&2; exit 1; }
grep -q '/fail' "$MOCK_LOG"

MOCK_VALAR_STATUS=active MOCK_RETI_STATUS=inactive \
run_heartbeat && { echo "inactive Reti should fail" >&2; exit 1; }
grep -q '/fail' "$MOCK_LOG"

MOCK_RETI_STATUS=active MOCK_CURL_FAIL=yes \
run_heartbeat && { echo "failed delivery should fail" >&2; exit 1; }

MOCK_CURL_FAIL=no MOCK_TIMEOUT_TARGET=partkeys run_heartbeat
assert_lines 0

touch "$TEST_DIR/network-degraded"
run_heartbeat
assert_lines 0
rm "$TEST_DIR/network-degraded"
run_heartbeat
assert_lines 1
echo "heartbeat tests passed"
