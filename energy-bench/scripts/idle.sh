#!/usr/bin/env bash
# Idle power: N windows of S seconds in which nothing runs; package and DRAM energy from RAPL.
# usage: sudo ./scripts/idle.sh <phase-label> <out.csv> [repeats] [seconds]
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root

PHASE="${1:?phase label, e.g. start}"
OUT="${2:?output csv}"
N="${3:-$IDLE_REPEATS}"
SECS="${4:-$IDLE_SEC}"

PKG="$(pkg_dir)"
DRAM="$(dram_dir || true)"
PMAX=$(cat "$PKG/max_energy_range_uj")
DMAX=$([[ -n "$DRAM" ]] && cat "$DRAM/max_energy_range_uj" || echo 0)

[[ -s "$OUT" ]] || echo "timestamp,phase,window,seconds,pkg_j,pkg_w,dram_j,dram_w,pkg_temp_c" >"$OUT"

read_dram() { if [[ -n "$DRAM" ]]; then cat "$DRAM/energy_uj"; else echo -1; fi; }

# CPU package temperature at the end of an idle window: a proxy for the room temperature over the run.
read_temp() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    if [[ "$(cat "$h/name" 2>/dev/null)" == coretemp ]]; then awk '{printf "%.1f", $1 / 1000}' "$h/temp1_input"; return; fi
  done
}

for w in $(seq 1 "$N"); do
  p0=$(cat "$PKG/energy_uj"); d0=$(read_dram); t0=$(date +%s%N)
  sleep "$SECS"
  p1=$(cat "$PKG/energy_uj"); d1=$(read_dram); t1=$(date +%s%N)
  dp=$((p1 - p0)); (( dp < 0 )) && dp=$((dp + PMAX))
  if (( d0 >= 0 )); then dd=$((d1 - d0)); (( dd < 0 )) && dd=$((dd + DMAX)); else dd=-1; fi
  line=$(awk -v ts="$(date -Is)" -v ph="$PHASE" -v w="$w" -v dt=$((t1 - t0)) -v dp="$dp" -v dd="$dd" -v tc="$(read_temp)" 'BEGIN {
      s = dt / 1e9
      dj = (dd < 0) ? "" : sprintf("%.4f", dd / 1e6)
      dw = (dd < 0) ? "" : sprintf("%.4f", dd / 1e6 / s)
      printf "%s,%s,%d,%.3f,%.4f,%.4f,%s,%s,%s", ts, ph, w, s, dp / 1e6, dp / 1e6 / s, dj, dw, tc }')
  echo "$line" >>"$OUT"
  echo "idle $PHASE window $w/$N: $(echo "$line" | awk -F, '{printf "package %.2f W  dram %s W  %s C", $6, ($8==""?"n/a":$8), $9}')"
done
