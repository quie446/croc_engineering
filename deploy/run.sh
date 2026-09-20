#!/bin/sh
# One-command orchestration for the croc integration stack:
# build (this commit) -> relay health gate -> real send/receive test.
#
# Exit codes identify the failing phase:
#   0  success
#   11 image build failed
#   12 relay failed its health check (or timed out)
#   13 integration test failed
#
# Environment:
#   COMPOSE_PROJECT_NAME  stack name, defaults to croc-it-<repo dir> so two
#                         checkouts never share a namespace; set it (e.g.
#                         croc-it-b) to run a second stack from one checkout
#   CROC_IT_WAIT_TIMEOUT  seconds to wait for relay health, default 120
#   CROC_IT_KEEP=1        keep containers/volumes after the run (debugging)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Default project name is derived from the checkout directory so that two
# clones of this repo on the same machine get disjoint compose namespaces
# (containers, networks, images) without any configuration.
REPO_SLUG=$(basename "$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)" \
    | tr -d '\n' | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | cut -c1-40)
PROJECT=${COMPOSE_PROJECT_NAME:-croc-it-$REPO_SLUG}
WAIT_TIMEOUT=${CROC_IT_WAIT_TIMEOUT:-120}
KEEP=${CROC_IT_KEEP:-0}

log() { printf '[orchestrator] %s\n' "$*"; }

compose() {
    docker compose --project-directory "$SCRIPT_DIR" \
        -f "$SCRIPT_DIR/compose.yaml" -p "$PROJECT" "$@"
}

if [ "${1:-}" = "--clean" ]; then
    compose down -v --remove-orphans
    exit $?
fi

if [ "$KEEP" != "1" ]; then
    # One-command cleanup: every run tears down its own containers,
    # networks, and volumes. `docker compose -p <name> down -v` does the
    # same manually.
    trap 'compose down -v --remove-orphans >/dev/null 2>&1 || true' EXIT
fi

COMMIT=$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo unknown)
log "project=$PROJECT commit=$COMMIT"

log "phase 1/3: building images from this commit (pinned base images)"
if ! compose build; then
    log "FAIL(build): image build failed"
    exit 11
fi

log "phase 2/3: starting relay, waiting for health (timeout ${WAIT_TIMEOUT}s)"
if ! compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" relay; then
    log "FAIL(healthcheck): relay did not become healthy"
    compose logs relay >&2 || true
    exit 12
fi

log "phase 3/3: running integration tests against the orchestrated binary"
test_status=0
compose run --rm -T tester || test_status=$?
if [ "$test_status" -ne 0 ]; then
    log "FAIL(tests): integration tests exited $test_status"
    log "---- relay logs ----"
    compose logs relay >&2 || true
    exit 13
fi

log "PASS: integration stack green"
