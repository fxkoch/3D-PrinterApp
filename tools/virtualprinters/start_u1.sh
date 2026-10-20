#!/usr/bin/env bash
# Starts a virtual Snapmaker U1 on :7125 – u1sim (a simulated Klipper with the U1's four tool heads,
# RFID filament data and print timing, MIT licence) under the unmodified Snapmaker Moonraker fork.
# Linux; needs git, curl and Python 3.11 (the fork's pinned dependencies).
#
#   tools/virtualprinters/start_u1.sh            # then: U1_HOST=127.0.0.1 swift test --filter U1VirtualPrintTests
#   U1SIM_SPEED=40 U1SIM_SCENARIO=four_color_print tools/virtualprinters/start_u1.sh
set -euo pipefail
WORK=${WORK:-$PWD/.virtualprinters}
SPEED=${U1SIM_SPEED:-40}
SCENARIO=${U1SIM_SCENARIO:-idle_loaded}
PY=${PYTHON:-python3}
U1_COMPANION_REV=69de50ed42d67b3902e6fce499bc850f283f1312   # github.com/zkasuran/u1-companion
MOONRAKER_REV=a308cfae31b7eb70ebf96bc73e6968d9792e4d73      # github.com/Snapmaker/u1-moonraker

fetch() {
  local dir=$1 url=$2 rev=$3
  if [ ! -d "$dir/.git" ]; then git init -q "$dir"; git -C "$dir" remote add origin "$url"; fi
  git -C "$dir" fetch -q --depth 1 origin "$rev"
  git -C "$dir" checkout -q FETCH_HEAD
}
mkdir -p "$WORK"
fetch "$WORK/u1-companion" https://github.com/zkasuran/u1-companion "$U1_COMPANION_REV"
fetch "$WORK/u1-moonraker" https://github.com/Snapmaker/u1-moonraker "$MOONRAKER_REV"

if [ ! -x "$WORK/venv/bin/python" ]; then
  "$PY" -m venv "$WORK/venv"
  grep -v '^#' "$WORK/u1-companion/docker/requirements-moonraker.txt" | grep -v '^$' > "$WORK/requirements.txt"
  "$WORK/venv/bin/pip" install -q -r "$WORK/requirements.txt"
fi

DATA=$WORK/data
mkdir -p "$DATA"/{logs,gcodes,database,comms,config/snapmaker,mqtt} "$WORK/tmp" "$WORK/run"
# The Snapmaker fork measures free space on the U1's /userdata partition before accepting uploads.
[ -d /userdata ] || sudo mkdir -p /userdata 2>/dev/null || mkdir -p /userdata
sed "s#/run/klippy/klippy.sock#$WORK/run/klippy.sock#" "$WORK/u1-companion/docker/moonraker.conf" > "$WORK/moonraker.conf"

(cd "$WORK/u1-companion" && nohup "$PY" -m u1sim --socket="$WORK/run/klippy.sock" --scenario="$SCENARIO" \
   --speed="$SPEED" --gcode-path="$DATA/gcodes" --config-file="$DATA/config/printer.cfg" \
   --log-file="$DATA/logs/klippy.log" > "$WORK/u1sim.log" 2>&1 &)
sleep 2
(cd "$WORK/u1-moonraker" && nohup "$WORK/venv/bin/python" -m moonraker -d "$DATA" -c "$WORK/moonraker.conf" \
   -t "$WORK/tmp" -n > "$WORK/moonraker.log" 2>&1 &)

for _ in $(seq 1 60); do
  if curl -s --noproxy '*' http://127.0.0.1:7125/server/info | grep -q '"klippy_state": "ready"'; then
    echo "Virtueller Snapmaker U1 bereit: http://127.0.0.1:7125"
    exit 0
  fi
  sleep 1
done
echo "Virtueller U1 startet nicht:" >&2
tail -40 "$WORK/u1sim.log" "$WORK/moonraker.log" >&2
exit 1
