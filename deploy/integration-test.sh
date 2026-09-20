#!/bin/sh
# End-to-end integration test running inside the orchestration's tester
# container: real `croc send` + real `croc` receive through the relay
# container, verified with a SHA-256 checksum.
#
# All log lines are prefixed [integration] so failures can be told apart
# from orchestrator and health-check output.
set -eu

log() { printf '[integration] %s\n' "$*"; }
fail() {
    printf '[integration] ERROR: %s\n' "$*" >&2
    exit 1
}

RELAY_HOST=${CROC_RELAY_HOST:-relay}
PORTS=${CROC_RELAY_PORTS:-9009,9010,9011,9012,9013}
CODE=${CROC_TEST_CODE:-croc-it-room}
TIMEOUT=${CROC_TRANSFER_TIMEOUT:-60}
FIXTURE=${CROC_FIXTURE:-/fixtures/payload.bin}

# --- provenance: prove we test the binary baked into this image ----------
CROC_BIN=$(command -v croc) || fail "no croc binary in this image"
log "binary under test: $CROC_BIN"
log "version: $(croc --version 2>&1 | head -n 1)"

[ -f "$FIXTURE" ] || fail "fixture $FIXTURE is missing"

CONTROL_PORT=${PORTS%%,*}
WORK=$(mktemp -d /tmp/croc-it.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- wait for the relay to accept connections on every port --------------
log "waiting for relay $RELAY_HOST ports: $PORTS (timeout ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
for port in $(echo "$PORTS" | tr ',' ' '); do
    until nc -z -w 2 "$RELAY_HOST" "$port" 2>/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "relay port $port unreachable after ${TIMEOUT}s"
        sleep 1
    done
done
log "relay reachable on all ports"

EXPECTED=$(sha256sum "$FIXTURE" | awk '{print $1}')
log "sending $FIXTURE (sha256 $EXPECTED) with room code '$CODE'"

mkdir -p "$WORK/recv"

# The room code travels via CROC_SECRET (the supported non-interactive
# path); on UNIX croc refuses secret codes as command-line arguments unless
# classic mode is enabled, and this test must not change CLI behavior.

# --- real send (first: the sender opens the relay room and waits) --------
timeout "$TIMEOUT" env CROC_SECRET="$CODE" croc --disable-clipboard \
    --ignore-stdin \
    --relay "$RELAY_HOST:$CONTROL_PORT" \
    send --no-local "$FIXTURE" >"$WORK/send.log" 2>&1 &
sender_pid=$!
sleep 2

# --- real receive ---------------------------------------------------------
timeout "$TIMEOUT" env CROC_SECRET="$CODE" croc --yes --overwrite --disable-clipboard \
    --relay "$RELAY_HOST:$CONTROL_PORT" \
    --out "$WORK/recv" >"$WORK/recv.log" 2>&1 &
receiver_pid=$!

dump_logs() {
    sed 's/^/[send] /' "$WORK/send.log" >&2 || true
    sed 's/^/[recv] /' "$WORK/recv.log" >&2 || true
}

if ! wait "$sender_pid"; then
    dump_logs
    fail "croc send failed"
fi

if ! wait "$receiver_pid"; then
    dump_logs
    fail "croc receive failed"
fi

RECEIVED="$WORK/recv/$(basename "$FIXTURE")"
[ -f "$RECEIVED" ] || fail "received file $RECEIVED is missing"
ACTUAL=$(sha256sum "$RECEIVED" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || fail "checksum mismatch: expected $EXPECTED got $ACTUAL"

log "checksum verified: $ACTUAL"
log "PASS: send + receive round trip through the orchestrated relay"
