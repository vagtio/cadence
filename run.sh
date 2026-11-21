#!/usr/bin/env bash
# Phase 0 spike: run unmodified LX 音源 scripts in JavaScriptCore (no Chromium).
#
#   ./run.sh            mock backend + full-surface fixture + a real community script
#   ./run.sh matrix     compatibility census over a cloned source collection
set -uo pipefail
cd "$(dirname "$0")"

COLLECTION="${LX_COLLECTION:-/tmp/lx-src}"
BIN=./.build/debug/lxspike
INFO='{"source":"kg","hash":"1f7e7659b9fff4fb6f71562a61bbc25f","songmid":"1f7e7659b9fff4fb6f71562a61bbc25f","name":"发如雪","singer":"周杰伦","interval":"04:59"}'

swift build 2>&1 | tail -1

if [[ "${1:-}" == "matrix" ]]; then
  printf "%-14s %-7s %-46s %s\n" SCRIPT SIZE SOURCES MS
  pass=0; failed=""
  shopt -s nullglob
  for f in "$COLLECTION"/*/latest.js; do
    name=$(basename "$(dirname "$f")")
    size=$(wc -c <"$f" | tr -d ' ')
    out=$($BIN "$f" --init-only 2>/dev/null)
    if grep -q '^init ok' <<<"$out"; then
      pass=$((pass + 1))
      printf "%-14s %-7s %-46s %s\n" "$name" "$size" \
        "$(sed 's/^init ok: //;s/  [0-9]* ms$//' <<<"$out" | cut -c1-46)" \
        "$(grep -o '[0-9]* ms$' <<<"$out" | tr -d ' ms')"
    else
      failed="$failed $name"
      printf "%-14s %-7s %-46s\n" "$name" "$size" "init failed"
    fi
  done
  echo
  echo "passed $pass script(s); failed:${failed:- none}"
  exit 0
fi

echo "── fixture: every lx surface (request/timers/crypto/buffer/zlib/fetch)"
python3 scripts/mock_server.py 8765 >/tmp/lxspike-mock.log 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null' EXIT
sleep 0.6
$BIN scripts/spike-source.js --source kg --quality 320k

echo
echo "── real: unmodified community script (helloworld, 21 KB)"
if [[ -f "$COLLECTION/helloworld/latest.js" ]]; then
  $BIN "$COLLECTION/helloworld/latest.js" --source kg --quality 128k --musicinfo "$INFO" --timeout 25
else
  echo "  skipped: clone https://github.com/pdone/lx-music-source into $COLLECTION"
fi
