#!/usr/bin/env bash
# Multiplayer smoke test: one host + one client on this machine (gta/tests/mp_host.gd, mp_client.gd).
#   tools/mp_test.sh <path to the Godot console exe> [log dir] [window]
# "window" runs both with a small window (screenshots land in qa/screenshots); default is headless.
GODOT="$1"; LOGS="${2:-/tmp/mp_logs}"; MODE="${3:-headless}"; HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$LOGS/host_data" "$LOGS/client_data"
cd "$HERE"
if [ "$MODE" = "window" ]; then
  HARGS="--windowed --resolution 1280x720 --position 20,40 --audio-driver Dummy"
  CARGS="--windowed --resolution 1280x720 --position 600,300 --audio-driver Dummy"
else
  HARGS="--headless"; CARGS="--headless"
fi
win() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
APPDATA="$(win "$LOGS/host_data")" timeout 190 "$GODOT" $HARGS --path . -- --host --name=HostDad --test=mp_host --test-timeout=170 --new-game > "$LOGS/host.log" 2>&1 &
HOST_PID=$!
sleep 16
APPDATA="$(win "$LOGS/client_data")" timeout 170 "$GODOT" $CARGS --path . -- --join=127.0.0.1 --name=ClientKid --test=mp_client --test-timeout=140 > "$LOGS/client.log" 2>&1
echo "client exit=$?"
wait $HOST_PID; echo "host exit=$?"
for f in host client; do echo "=== $f ==="; grep -E "TEST_|SCRIPT ERROR|\[Net\]|ERROR: |SHOT_SAVED" "$LOGS/$f.log" | cut -c1-240 | head -60; done
