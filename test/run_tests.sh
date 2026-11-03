#!/bin/bash
# End-to-end test of bin/gopeed-dl against test/mock_gopeed.rb.
# Usage: test/run_tests.sh   (expects bin/gopeed-dl to exist; run ./build.sh first)
set -uo pipefail
cd "$(dirname "$0")/.."
PORT=19876
PORT2=19877
SOCK="$(pwd)/test/.mock.sock"
export GOPEED_URL="http://127.0.0.1:$PORT"

ruby test/mock_gopeed.rb "$PORT" "$SOCK" > /tmp/mock_gopeed.log 2>&1 &
MOCK=$!
trap 'kill $MOCK $MOCK2 2>/dev/null; rm -f "$SOCK"' EXIT
sleep 0.5

fail=0
check() { # check <label> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected to contain [$2], got: $3"
    fail=1
  fi
}

out=$(./bin/gopeed-dl ping 2>&1);            check "ping"        "gopeed 1.7.0-mock" "$out"
out=$(./bin/gopeed-dl add 2>&1);              check "add-no-url"  "usage: gopeed-dl add" "$out"
out=$(./bin/gopeed-dl add http://x.test/big.bin --name big.bin --dir /tmp/dl 2>&1); check "add" "added task task-1" "$out"
out=$(./bin/gopeed-dl remove 2>&1);           check "remove-no-id" "missing task id" "$out"
out=$(./bin/gopeed-dl remove 'task-1;x' 2>&1); check "bad-id"     "invalid task id" "$out"
out=$(./bin/gopeed-dl list 2>&1);             check "list-kept"   "task-1" "$out"
out=$(./bin/gopeed-dl status boom 2>&1);      check "plain-500"   "not a JSON API reply" "$out"
out=$(./bin/gopeed-dl wait task-1 --timeout abc 2>&1); check "bad-timeout" "bad --timeout" "$out"
out=$(./bin/gopeed-dl list 2>&1);             check "list"        "start" "$out"
out=$(./bin/gopeed-dl status task-1 2>&1);    check "status"      "status:   start" "$out"
out=$(./bin/gopeed-dl pause task-1 2>&1);     check "pause"       "paused task-1" "$out"
out=$(./bin/gopeed-dl status task-1 2>&1);    check "paused-st"   "status:   pause" "$out"
out=$(./bin/gopeed-dl continue task-1 2>&1);  check "continue"    "continued task-1" "$out"
out=$(./bin/gopeed-dl wait task-1 --timeout 30 2>&1); check "wait done" "done" "$out"; check "wait saved" "saved to: /tmp/dl/big.bin" "$out"
out=$(./bin/gopeed-dl remove task-1 --force 2>&1); check "remove"   "removed task-1" "$out"
out=$(./bin/gopeed-dl list 2>&1);             check "empty list"  "no tasks" "$out"
out=$(./bin/gopeed-dl status task-1 2>&1);    check "gone err"    "task not found" "$out"

# token path (separate port: the first mock is still bound to $PORT)
MOCK2=""
MOCK_TOKEN=sekret ruby test/mock_gopeed.rb "$PORT2" > /tmp/mock_gopeed2.log 2>&1 &
MOCK2=$!
sleep 0.5
out=$(GOPEED_URL="http://127.0.0.1:$PORT2" GOPEED_TOKEN=wrong ./bin/gopeed-dl ping 2>&1); check "bad token" "gopeed error: unauthorized" "$out"
out=$(GOPEED_URL="http://127.0.0.1:$PORT2" GOPEED_TOKEN=sekret ./bin/gopeed-dl ping 2>&1); check "good token" "gopeed 1.7.0-mock" "$out"

# unix-socket transport (strict GOPEED_URL=unix://...)
out=$(GOPEED_URL="unix://$SOCK" ./bin/gopeed-dl ping 2>&1);                 check "unix ping"   "gopeed 1.7.0-mock" "$out"
out=$(GOPEED_URL="unix://$SOCK" ./bin/gopeed-dl add http://x.test/u.bin --name u.bin --dir /tmp/dl 2>&1); check "unix add" "added task task-2" "$out"
out=$(GOPEED_URL="unix://$SOCK" ./bin/gopeed-dl status task-2 2>&1);        check "unix status" "status:   start" "$out"
out=$(GOPEED_URL="unix://$SOCK" ./bin/gopeed-dl remove task-2 --force 2>&1); check "unix remove" "removed task-2" "$out"

# auto-detect: GOPEED_URL unset, GOPEED_SOCK points at the mock socket
out=$(env -u GOPEED_URL GOPEED_SOCK="$SOCK" ./bin/gopeed-dl ping 2>&1);     check "auto unix"   "gopeed 1.7.0-mock" "$out"

# doctor output
out=$(GOPEED_URL="unix://$SOCK" ./bin/gopeed-dl doctor 2>&1);              check "doctor api"   "gopeed 1.7.0-mock" "$out"; check "doctor ok" "OK" "$out"; check "doctor token" "token: not set" "$out"

# strict dead endpoint and missing --timeout value
out=$(GOPEED_URL="http://127.0.0.1:1" ./bin/gopeed-dl ping 2>&1);          check "dead tcp"    "cannot reach gopeed" "$out"
out=$(./bin/gopeed-dl wait task-1 --timeout 2>&1);                          check "timeout-missing" "bad --timeout" "$out"

# heap self-check: forced via GOPEEDSELFCHECK=1, must print on success AND error paths
out=$(GOPEEDSELFCHECK=1 ./bin/gopeed-dl ping 2>&1);                        check "selfcheck ok"  "gopeed-dl self-check: heap_bytes=" "$out"
out=$(GOPEEDSELFCHECK=1 GOPEED_URL="http://127.0.0.1:1" ./bin/gopeed-dl ping 2>&1); check "selfcheck err" "gopeed-dl self-check: heap_bytes=" "$out"

echo "---"
if [ "$fail" = 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
