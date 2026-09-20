#!/bin/sh
# Real send + real receive through the orchestrated relay, verified by
# checksum. Runs inside the e2e container; every croc invocation is wrapped
# in `timeout` so a hung transfer fails instead of blocking the pipeline.
set -eu

log()  { printf '[it:e2e] %s\n' "$*"; }
fail() { printf '[it:e2e] FAIL: %s\n' "$*" >&2; exit 1; }

CODE=${CROC_IT_CODE:?CROC_IT_CODE must be set}
RELAY=${CROC_RELAY:?CROC_RELAY must be set}
TIMEOUT=${CROC_IT_TIMEOUT:-60}
FIXTURES=${CROC_IT_FIXTURES:-/fixtures}
RECEIVED=${CROC_IT_RECEIVED:-/received}
WORK=${CROC_IT_WORK:-/work}
PAYLOAD="$WORK/payload.bin"

log "revision: $(cat /etc/croc-it-revision 2>/dev/null || echo unknown)"
log "binary: $(croc --version 2>&1 | head -n 1)"
log "relay: $RELAY  code: $CODE  timeout: ${TIMEOUT}s"

# Defense in depth on top of the compose healthcheck: the relay port must be
# connectable from the client container before any transfer is attempted.
deadline=$(( $(date +%s) + TIMEOUT ))
while ! nc -z -w 2 "${RELAY%%:*}" "${RELAY##*:}"; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "relay $RELAY not reachable within ${TIMEOUT}s"
    sleep 1
done
log "relay port reachable"

# Payload: dev-seeded fixture if present, else a deterministic generated file.
mkdir -p "$WORK" "$RECEIVED"
if [ -f "$FIXTURES/payload.bin" ]; then
    cp "$FIXTURES/payload.bin" "$PAYLOAD"
    log "using seeded fixture $FIXTURES/payload.bin"
else
    i=0
    : > "$PAYLOAD"
    while [ "$i" -lt 64 ]; do
        printf 'croc-it-payload line %04d\n' "$i" >> "$PAYLOAD"
        i=$((i + 1))
    done
    log "generated deterministic payload"
fi
SUM=$(sha256sum "$PAYLOAD" | awk '{print $1}')
log "payload sha256: $SUM"

# Real send through the relay. On UNIX, croc requires custom code phrases via
# CROC_SECRET (not --code, on either side); the relay address comes from the
# CROC_RELAY env var so subcommand flag parsing stays untouched; --no-local
# forces the transfer through the orchestrated relay.
CROC_SECRET=$CODE timeout "$TIMEOUT" croc \
    --ignore-stdin --disable-clipboard \
    send --no-local "$PAYLOAD" >"$WORK/send.log" 2>&1 &
sender=$!

if ! CROC_SECRET=$CODE timeout "$TIMEOUT" croc --yes --overwrite \
        --ignore-stdin --disable-clipboard --out "$RECEIVED" \
        >"$WORK/recv.log" 2>&1; then
    cat "$WORK/send.log" "$WORK/recv.log" >&2 || true
    fail "croc receive failed (send/receive logs above)"
fi
if ! wait "$sender"; then
    cat "$WORK/send.log" >&2 || true
    fail "croc send exited non-zero (send log above)"
fi

GOT=$(sha256sum "$RECEIVED/payload.bin" | awk '{print $1}')
[ "$GOT" = "$SUM" ] || fail "checksum mismatch: sent $SUM, received $GOT"
log "checksum verified: $GOT"
log "PASS"
