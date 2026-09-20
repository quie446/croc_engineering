#!/bin/sh
# Unit/self tests, mirroring the package selection of .github/workflows/ci.yml
# so the orchestration exercises the same suites CI trusts. Runs inside the
# tester container against this commit's source; `go test -timeout` bounds
# every package so nothing hangs the pipeline.
set -eu

log() { printf '[it:unit] %s\n' "$*"; }

cd /src
log "go: $(go version)"
log "revision: $(cat /out/REVISION 2>/dev/null || echo unknown)"

run() {
    log "go test $*"
    go test -count=1 -timeout 180s "$@"
}

run ./src/receivefs ./src/redact ./src/pakekey
run ./src/utils -run 'Test(UnzipDirectory|RemoveMarkedFiles|ValidFileName)'
run ./src/storecrypto ./src/storeclient -run 'Test(ValidateManifest|Stored|Receive)'
run ./src/tcp -run 'Test(AdmissionLimiter|RoomDenials|RelayAdmissionLimits|CanonicalSource|WithAdmissionLimits|ConnectToTCPServerControlContext)'
run ./src/sshshare
run ./src/comm -run 'Test(ReceiveWithDeadlineLimit|NewConnectionContext)'
run ./src/message -run 'TestDecodeWithLimit'
run ./src/croc -run 'Test(HostilePortable|MarkedArchive|UnmarkedArchive|LocalIPExchange|FailedPakeConfirmation|ClientErrorsRedact)'
run .

log "PASS"
