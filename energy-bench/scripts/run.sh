#!/usr/bin/env bash
# Runs every launch in a plan file: one fresh JVM per line, in the order of the (shuffled) plan.
# Safe to restart: launches listed in <outdir>/done.txt are skipped, so after a crash or reboot
# you run the same command again and it continues where it stopped.
#
# usage: sudo ./scripts/run.sh <plan.tsv> <outdir>
#   FORCE=1 sudo -E ./scripts/run.sh ...   start even when precheck reports a FAIL (only for testing)
#
# Output in <outdir>:
#   results.csv        one line per repetition (written by bench.Bench), only from launches that ended
#   aborted_rows.csv   rows of launches that were interrupted by Ctrl-C/reboot (those launches are re-run)
#   idle.csv           idle power windows (start / mid / end)
#   failures.csv       launches that crashed (rc != 0), timed out (rc 124/137) or had a wrong checksum (rc 3)
#   progress.log       one line per launch with duration and ETA (human readable)
#   launches.csv       one line per launch: exit code, start time, wall-clock duration in ms
#   bench.log          stdout/stderr of all launches
#   precheck_*.txt, machine_state_*.txt, plan.tsv, config.env, echo_server.log
set -uo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root
require_build

PLAN="${1:?usage: run.sh <plan.tsv> <outdir>}"
OUT="${2:?usage: run.sh <plan.tsv> <outdir>}"
SESSION="$(basename "$OUT")"
mkdir -p "$OUT"
touch "$OUT/done.txt"

RESUME=0
[[ -s "$OUT/done.txt" ]] && RESUME=1
if [[ -f "$OUT/plan.tsv" ]] && ! cmp -s "$PLAN" "$OUT/plan.tsv"; then
  echo "$OUT already contains a different plan.tsv; use a new output directory." >&2
  exit 1
fi
[[ "$(realpath "$PLAN")" == "$(realpath -m "$OUT/plan.tsv")" ]] || cp "$PLAN" "$OUT/plan.tsv"
# A resumed run must use the same settings as the part that already ran.
if [[ -f "$OUT/config.env" ]] && ! cmp -s "$ROOT/config.env" "$OUT/config.env" && [[ "${FORCE:-0}" != "1" ]]; then
  echo "config.env changed since this run started (diff below). Restore it, or use a new output directory." >&2
  diff "$OUT/config.env" "$ROOT/config.env" >&2
  exit 1
fi
cp "$ROOT/config.env" "$OUT/config.env"
{ echo "# effective settings at $(date -Is) (config.env plus overrides from the environment)"
  for v in $(grep -oE '^[A-Z_]+=' "$ROOT/config.env" | tr -d '='); do echo "$v=${!v}"; done
  echo "AXES_ONLY=${AXES_ONLY:-}"; echo; } >>"$OUT/settings.log"

ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== precheck"
if ! "$ROOT/scripts/precheck.sh" | tee "$OUT/precheck_$STAMP.txt"; then
  if [[ "${FORCE:-0}" != "1" ]]; then
    echo "precheck failed; fix it (sudo ./scripts/precheck.sh --fix) or use FORCE=1 for a test run." >&2
    exit 1
  fi
  echo "FORCE=1: continuing despite precheck failures" | tee -a "$OUT/precheck_$STAMP.txt"
fi
"$ROOT/scripts/machine_state.sh" >"$OUT/machine_state_$STAMP.txt" 2>&1

# Append the rows of one launch to a CSV, writing the header only once.
append_rows() {
  local src="$1" dst="$2"
  [[ -s "$src" ]] || return 0
  if [[ -s "$dst" ]]; then tail -n +2 "$src" >>"$dst"; else cat "$src" >"$dst"; fi
}

cleanup() {
  stop_echo_server
  give_back "$OUT"
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM

if awk -F'\t' 'NR > 1 && $3 == "C" { found = 1 } END { exit !found }' "$PLAN"; then
  echo "== starting echo server for benchmark C on port $PORT"
  start_echo_server "$OUT/echo_server.log" || exit 1
fi

echo "== idle power ($IDLE_REPEATS x ${IDLE_SEC}s)"
"$ROOT/scripts/idle.sh" "$([[ $RESUME -eq 1 ]] && echo resume || echo start)" "$OUT/idle.csv"
LAST_IDLE=$(date +%s)

# Rows of a launch that was interrupted (Ctrl-C, reboot) are kept apart; that launch runs again.
if [[ -s "$OUT/current.csv" ]]; then
  append_rows "$OUT/current.csv" "$OUT/aborted_rows.csv"
  rm -f "$OUT/current.csv"
fi

TOTAL=$(($(wc -l <"$PLAN") - 1))
DONE_BEFORE=$(wc -l <"$OUT/done.txt")
RUN_COUNT=0
RUN_SECS=0
echo "== $TOTAL launches in plan, $DONE_BEFORE already done; session tag '$SESSION'"

N=0
while IFS=$'\t' read -r ID LNO BM CONS B C REPS WARM; do
  [[ "$ID" == "launch_id" ]] && continue
  N=$((N + 1))
  grep -qxF "$ID" "$OUT/done.txt" && continue

  case "$BM" in B) ITERS=$ITERS_B ;; *) ITERS=$ITERS_A ;; esac
  T0=$(date +%s%N)
  timeout --kill-after=30 "$LAUNCH_TIMEOUT_SEC" \
    "$JAVA" $JVM_FLAGS -cp "$ROOT/build" bench.Bench \
      --benchmark "$BM" --construct "$CONS" --b "$B" --C "$C" \
      --iters "$ITERS" --tasks "$TASKS" --reps "$REPS" --warmup "$WARM" \
      --cores "$CORES" --tcpu-ns "$TCPU_NS" --port "$PORT" --rapl-root "$RAPL_ROOT" \
      --out "$OUT/current.csv" --session "$SESSION" --launch-id "$ID" --launch-no "$LNO" \
      </dev/null >>"$OUT/bench.log" 2>&1
  RC=$?
  T1=$(date +%s%N)
  DT=$(((T1 - T0) / 1000000000))
  [[ -s "$OUT/launches.csv" ]] || echo "launch_id,exit_code,start_epoch_ms,duration_ms" >"$OUT/launches.csv"
  echo "$ID,$RC,$((T0 / 1000000)),$(((T1 - T0) / 1000000))" >>"$OUT/launches.csv"
  append_rows "$OUT/current.csv" "$OUT/results.csv"
  rm -f "$OUT/current.csv"

  if [[ $RC -ne 0 ]]; then
    case $RC in 3) WHY=checksum ;; 124|137) WHY=timeout ;; *) WHY=crash ;; esac
    [[ -s "$OUT/failures.csv" ]] || echo "timestamp,launch_id,exit_code,reason,seconds" >"$OUT/failures.csv"
    echo "$(date -Is),$ID,$RC,$WHY,$DT" >>"$OUT/failures.csv"
  fi
  echo "$ID" >>"$OUT/done.txt"

  RUN_COUNT=$((RUN_COUNT + 1))
  RUN_SECS=$((RUN_SECS + DT + PAUSE_SEC))
  LEFT=$((TOTAL - $(wc -l <"$OUT/done.txt")))
  ETA=$((RUN_SECS / RUN_COUNT * LEFT))
  printf '%s [%d/%d] %-28s rc=%d %4ds  left %d  eta %dh%02dm\n' "$(date +%H:%M:%S)" "$N" "$TOTAL" "$ID" "$RC" "$DT" \
    "$LEFT" $((ETA / 3600)) $((ETA % 3600 / 60)) | tee -a "$OUT/progress.log"

  if [[ "$IDLE_EVERY_SEC" -gt 0 && $(($(date +%s) - LAST_IDLE)) -ge "$IDLE_EVERY_SEC" && $LEFT -gt 0 ]]; then
    "$ROOT/scripts/idle.sh" mid "$OUT/idle.csv" 2 "$IDLE_SEC"
    LAST_IDLE=$(date +%s)
  fi
  sleep "$PAUSE_SEC"
done <"$PLAN"

echo "== idle power (end)"
"$ROOT/scripts/idle.sh" end "$OUT/idle.csv"
"$ROOT/scripts/machine_state.sh" >"$OUT/machine_state_end_$(date +%Y%m%d-%H%M%S).txt" 2>&1

FAILED=$([[ -f "$OUT/failures.csv" ]] && echo $(($(wc -l <"$OUT/failures.csv") - 1)) || echo 0)
echo "== finished: $(wc -l <"$OUT/done.txt")/$TOTAL launches done, $FAILED failed. Results: $OUT/results.csv"
