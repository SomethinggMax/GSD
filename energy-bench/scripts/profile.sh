#!/usr/bin/env bash
# JFR profiling runs for Table 8 of the paper (Section 7.6). One launch per construct for each of
# five workloads, with the same JVM flags, REPS and WARMUP as the main experiment, plus a JFR
# recording (settings=profile). Never combined with the energy measurements: the RAPL numbers of
# these launches are written to results.csv but are not used.
#
#   sudo ./scripts/profile.sh            -> results/profile/
#
# Output in results/profile/:
#   <bench>-<construct>-b<b>-C<C>.jfr   the recording (open in JDK Mission Control, or `jfr print`)
#   *.summary.txt                       `jfr summary` of each recording
#   profile.csv                         per launch: thread starts, parks, pinned events, GCs, mean CPU load
# Then: python analysis/jfr_table.py  (or analysis/reproduce.py) makes Table 8 from profile.csv.
set -uo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root
require_build

DIR="$ROOT/results/profile"
mkdir -p "$DIR"
CP="$ROOT/build"
JFR="$(dirname "$(readlink -f "$(command -v "$JAVA")")")/jfr"
[[ -x "$JFR" ]] || { echo "jfr tool not found next to $JAVA" >&2; exit 1; }
trap 'stop_echo_server; give_back "$DIR"' EXIT

# benchmark b C  (the rows of Table 8)
WORKLOADS=("A 0 10" "A 0.5 1000" "A 0.95 1000" "B 0.5 1000" "C 0.5 1000")
CONSTRUCTS=(explicit pool fj vt)

"$ROOT/scripts/precheck.sh" | tee "$DIR/precheck.txt" || { [[ "${FORCE:-0}" == 1 ]] || exit 1; }
"$ROOT/scripts/machine_state.sh" >"$DIR/machine_state.txt" 2>&1
start_echo_server "$DIR/echo_server.log" || exit 1

count() { awk -v ev="$1" '$1 == ev { print $2; found = 1 } END { if (!found) print 0 }' "$2"; }

echo "benchmark,construct,b,C,reps,tasks,thread_starts,parks,pinned,gcs,cpu_machine_pct,cpu_jvm_pct" >"$DIR/profile.csv"
for w in "${WORKLOADS[@]}"; do
  read -r BM B C <<<"$w"
  case "$BM" in B) ITERS=$ITERS_B ;; *) ITERS=$ITERS_A ;; esac
  for CONS in "${CONSTRUCTS[@]}"; do
    NAME="$BM-$CONS-b$B-C$C"
    echo "== $NAME"
    "$JAVA" $JVM_FLAGS -XX:StartFlightRecording=filename="$DIR/$NAME.jfr",settings=profile,dumponexit=true \
      -cp "$CP" bench.Bench --benchmark "$BM" --construct "$CONS" --b "$B" --C "$C" \
      --iters "$ITERS" --tasks "$TASKS" --reps "$REPS" --warmup "$WARMUP" --cores "$CORES" --tcpu-ns "$TCPU_NS" \
      --port "$PORT" --rapl-root "$RAPL_ROOT" --out "$DIR/results.csv" --session profile --launch-id "$NAME" \
      </dev/null >>"$DIR/bench.log" 2>&1 || echo "WARN: $NAME exited with $?"
    "$JFR" summary "$DIR/$NAME.jfr" >"$DIR/$NAME.summary.txt"
    S="$DIR/$NAME.summary.txt"
    CPU=$("$JFR" print --events jdk.CPULoad "$DIR/$NAME.jfr" | awk '
      /machineTotal/ { gsub("%", "", $3); m += $3; n++ }
      /jvmUser|jvmSystem/ { gsub("%", "", $3); j += $3 }
      END { if (n) printf "%.1f,%.1f", m / n, j / n; else printf "," }')
    echo "$BM,$CONS,$B,$C,$REPS,$TASKS,$(count jdk.ThreadStart "$S"),$(count jdk.ThreadPark "$S"),$(count jdk.VirtualThreadPinned "$S"),$(count jdk.GarbageCollection "$S"),$CPU" \
      | tee -a "$DIR/profile.csv"
    sleep "$PAUSE_SEC"
  done
done
echo "profiling done -> $DIR/profile.csv"
