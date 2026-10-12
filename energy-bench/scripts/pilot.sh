#!/usr/bin/env bash
# The pilot from the test plan, one step per command. Results go to results/pilot/<step>/.
#
#   sudo ./scripts/pilot.sh p1   instrument checks: precheck, RAPL domains, counter update rate, idle power   (~10 min)
#   sudo ./scripts/pilot.sh p2   calibration: iterations for t_cpu ~ 1 ms (A, B), sleep and socket accuracy (~10 min)
#                                -> then put ITERS_A / ITERS_B in config.env
#   sudo ./scripts/pilot.sh p3   smoke test: all 240 configurations, 1 launch, 2 repetitions                 (~2 h)
#   sudo ./scripts/pilot.sh p4   variance/warm-up: A and C, 4 workloads, 10 launches, 15 repetitions         (~8-10 h)
#   sudo ./scripts/pilot.sh p5   JFR trial: VT and ForkJoin at b=0.95, C=100, with and without JFR           (~15 min)
#
# Start long steps (p3, p4) inside tmux or with systemd-run so they survive a dropped SSH session:
#   sudo systemd-run --unit=pilot-p4 --working-directory="$PWD" ./scripts/pilot.sh p4
#   journalctl -fu pilot-p4      (follow)       ./scripts/status.sh results/pilot/p4
set -uo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root
require_build

STEP="${1:?usage: pilot.sh p1|p2|p3|p4|p5}"
DIR="$ROOT/results/pilot/$STEP"
mkdir -p "$DIR"
CP="$ROOT/build"
trap 'stop_echo_server; give_back "$ROOT/results"' EXIT

need_calibration() {
  if grep -q PLACEHOLDER "$ROOT/config.env" && [[ "${FORCE:-0}" != "1" ]]; then
    echo "config.env still has PLACEHOLDER iteration counts: run p2 first and fill in ITERS_A / ITERS_B." >&2
    exit 1
  fi
}

case "$STEP" in
  p1)
    "$ROOT/scripts/precheck.sh" | tee "$DIR/precheck.txt"
    "$ROOT/scripts/machine_state.sh" >"$DIR/machine_state.txt" 2>&1
    echo; echo "== RAPL domains and counter update interval"
    "$JAVA" -cp "$CP" bench.Calib rapl --rapl-root "$RAPL_ROOT" 2>&1 | tee "$DIR/rapl.txt"
    echo; echo "== DRAM counter under memory load (should increase clearly compared to idle)"
    if D="$(dram_dir)"; then
      d0=$(cat "$D/energy_uj"); "$JAVA" -Xms2g -Xmx2g -XX:+AlwaysPreTouch -version >/dev/null 2>&1; d1=$(cat "$D/energy_uj")
      echo "dram energy while pre-touching a 2 GB heap: $(( (d1 - d0) / 1000 )) mJ" | tee -a "$DIR/rapl.txt"
    else
      echo "no dram domain" | tee -a "$DIR/rapl.txt"
    fi
    echo; echo "== idle power"
    "$ROOT/scripts/idle.sh" p1 "$DIR/idle.csv"
    echo; echo "p1 done -> $DIR"
    ;;

  p2)
    echo "== iterations for t_cpu = ${TCPU_NS} ns, benchmark A (C uses the same loop)"
    "$JAVA" $JVM_FLAGS -cp "$CP" bench.Calib k --benchmark A --target-ns "$TCPU_NS" --cores "$CORES" 2>&1 | tee "$DIR/k_A.txt"
    echo; echo "== iterations for t_cpu = ${TCPU_NS} ns, benchmark B"
    "$JAVA" $JVM_FLAGS -cp "$CP" bench.Calib k --benchmark B --target-ns "$TCPU_NS" --cores "$CORES" 2>&1 | tee "$DIR/k_B.txt"
    echo; echo "== blocking-phase accuracy: Thread.sleep and socket round trip, platform vs virtual thread"
    start_echo_server "$DIR/echo_server.log" || exit 1
    "$JAVA" -cp "$CP" bench.Calib sleep --tcpu-ns "$TCPU_NS" --socket "$PORT" 2>&1 | tee "$DIR/blocking.csv"
    stop_echo_server
    echo
    echo "p2 done -> $DIR"
    echo "Now edit config.env: set ITERS_A and ITERS_B to the values above and remove the word PLACEHOLDER."
    grep -h 'put this' "$DIR"/k_*.txt
    ;;

  p3)
    need_calibration
    [[ -f "$DIR/plan.tsv" ]] || "$JAVA" -cp "$CP" bench.Plan --mode all --launches 1 --reps 2 --warmup 1 \
      --seed "$SEED" --out "$DIR/plan.tsv"
    "$ROOT/scripts/run.sh" "$DIR/plan.tsv" "$DIR"
    echo; "$ROOT/scripts/estimate.sh" "$DIR" | tee "$DIR/estimate.txt"
    ;;

  p4)
    need_calibration
    [[ -f "$DIR/plan.tsv" ]] || "$JAVA" -cp "$CP" bench.Plan --mode all --benchmarks A,C \
      --workloads 0:100,0.95:100,0:10000,0.5:1000 --launches 10 --reps 15 --warmup 7 --seed "$SEED" --out "$DIR/plan.tsv"
    "$ROOT/scripts/run.sh" "$DIR/plan.tsv" "$DIR"
    ;;

  p5)
    need_calibration
    JFR="$(dirname "$(readlink -f "$(command -v "$JAVA")")")/jfr"
    for CONS in vt fj; do
      for MODE in nojfr jfr; do
        EXTRA=""
        [[ $MODE == jfr ]] && EXTRA="-XX:StartFlightRecording=filename=$DIR/A-$CONS.jfr,settings=profile,dumponexit=true"
        echo "== benchmark A, $CONS, b=0.95, C=100, $MODE"
        "$JAVA" $JVM_FLAGS $EXTRA -cp "$CP" bench.Bench --benchmark A --construct "$CONS" --b 0.95 --C 100 \
          --iters "$ITERS_A" --tasks "$TASKS" --reps 4 --warmup 2 --cores "$CORES" --tcpu-ns "$TCPU_NS" \
          --rapl-root "$RAPL_ROOT" --out "$DIR/results.csv" --session "p5-$MODE" --launch-id "A-$CONS-$MODE" 2>&1 | tee -a "$DIR/bench.log"
        sleep "$PAUSE_SEC"
      done
      if [[ -x "$JFR" ]]; then
        "$JFR" summary "$DIR/A-$CONS.jfr" >"$DIR/A-$CONS.summary.txt"
        for ev in jdk.VirtualThreadPinned jdk.ThreadPark jdk.GarbageCollection jdk.ThreadStart; do
          printf '%-28s %s events\n' "$ev" "$("$JFR" print --events "$ev" "$DIR/A-$CONS.jfr" | grep -c "^$ev")"
        done | tee "$DIR/A-$CONS.events.txt"
      fi
    done
    echo "p5 done -> $DIR  (open the .jfr files in JDK Mission Control, or: jfr print --events <name> <file>)"
    ;;

  *)
    echo "unknown step $STEP (use p1..p5)" >&2; exit 1 ;;
esac
