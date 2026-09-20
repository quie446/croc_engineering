#!/bin/sh
# One-command croc integration orchestration:
# build (pinned) -> relay health gate -> unit tests -> real send/receive e2e.
#
# Usage:
#   ./deploy/it/run.sh            # full pipeline, auto-cleanup
#   ./deploy/it/run.sh clean      # tear down the stack and its volumes
#
# Parallel stacks on one host (nothing is published to the host, all state is
# project-scoped):
#   CROC_IT_PROJECT=croc-it-2 ./deploy/it/run.sh
#
# Knobs (env): CROC_IT_PROJECT, CROC_IT_PORTS, CROC_IT_CODE,
#   CROC_IT_HEALTH_TIMEOUT, CROC_IT_E2E_TIMEOUT, CROC_IT_KEEP,
#   CROC_IT_PUBLISH, CROC_IT_FIXTURES_DIR
set -eu

log() { printf '[it:run] %s\n' "$*" >&2; }
die() { printf '[it:run] FAIL(stage=%s): %s\n' "${stage:-setup}" "$*" >&2; exit 1; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

# Compose project/files are passed via env so paths with spaces never get
# word-split by an unquoted command variable. The default project name carries
# a hash of the repo path so two checkouts on one machine (or two worktrees)
# never adopt each other's containers, networks, or volumes.
DEFAULT_PROJECT="croc-it-$(printf '%s' "$ROOT" | cksum | awk '{print $1}')"
export CROC_IT_PROJECT=${CROC_IT_PROJECT:-$DEFAULT_PROJECT}
export COMPOSE_PROJECT_NAME=$CROC_IT_PROJECT
export CROC_IT_PORTS=${CROC_IT_PORTS:-9009,9010,9011,9012,9013}
export CROC_IT_RELAY_PORT=${CROC_IT_RELAY_PORT:-${CROC_IT_PORTS%%,*}}
export CROC_IT_CODE=${CROC_IT_CODE:-it-${CROC_IT_PROJECT}-room}
export CROC_IT_REVISION=${CROC_IT_REVISION:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}
CROC_IT_HEALTH_TIMEOUT=${CROC_IT_HEALTH_TIMEOUT:-120}

COMPOSE_FILE="$HERE/compose.yml"
[ "${CROC_IT_PUBLISH:-0}" = "1" ] && COMPOSE_FILE="$COMPOSE_FILE:$HERE/compose.publish.yml"
[ -n "${CROC_IT_FIXTURES_DIR:-}" ] && COMPOSE_FILE="$COMPOSE_FILE:$HERE/compose.dev.yml"
export COMPOSE_FILE

command -v docker >/dev/null 2>&1 || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found"

if [ "${1:-}" = "clean" ]; then
    docker compose down -v --remove-orphans
    log "stack $CROC_IT_PROJECT removed (containers, network, volumes)"
    exit 0
fi

cleanup() {
    if [ "${CROC_IT_KEEP:-0}" != "1" ]; then
        docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Run a one-shot service to completion, stream its logs, return its exit code.
run_service() {
    name=$1
    docker compose up -d --no-deps --force-recreate "$name" >/dev/null
    cid=$(docker compose ps -q "$name")
    code=$(docker wait "$cid")
    docker compose logs --no-color "$name" >&2 || true
    [ "$code" = "0" ]
}

log "project=$CROC_IT_PROJECT revision=$CROC_IT_REVISION"
log "ports=$CROC_IT_PORTS code=$CROC_IT_CODE"

stage=config
docker compose config -q || die "compose file invalid"

stage=build
log "building images (base images pinned by digest)"
docker compose build || die "image build failed"

stage=health
log "starting relay, waiting for health (timeout ${CROC_IT_HEALTH_TIMEOUT}s)"
if ! docker compose up -d --wait --timeout "$CROC_IT_HEALTH_TIMEOUT" relay; then
    docker compose logs --no-color relay >&2 || true
    die "relay did not become healthy"
fi
log "relay healthy"

stage=unit
log "running unit tests"
run_service unit || die "unit tests failed"
log "unit tests passed"

stage=e2e
log "running real send/receive transfer"
run_service e2e || die "e2e transfer failed"
log "e2e transfer passed"

log "PASS: build + health + unit + e2e (project $CROC_IT_PROJECT)"
