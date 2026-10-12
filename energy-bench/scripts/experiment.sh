#!/usr/bin/env bash
# The main experiment. Two ways to run it (same seed, same configurations):
#
#   sudo ./scripts/experiment.sh all          every launch of every configuration in one shuffled list
#                                             -> results/main-all
#   sudo ./scripts/experiment.sh session 3    launch number 3 of every configuration (one "session"),
#                                             shuffled with seed+3 -> results/main-s03; run sessions 1..LAUNCHES
#
# Options through the environment (defaults from config.env):
#   LAUNCHES=7 REPS=10 WARMUP=5 AXES_ONLY=B,C sudo -E ./scripts/experiment.sh all
#   AXES_ONLY=B,C: benchmarks B and C only at C=100 (all b, RQ2) and b=0 (all C, RQ3)
#
# Run it detached so it survives a dropped SSH/Tailscale connection:
#   sudo systemd-run --unit=exp-all --working-directory="$PWD" ./scripts/experiment.sh all
#   ./scripts/status.sh results/main-all
# If it stops (crash, reboot), run the same command again: it continues where it stopped.
set -uo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root
require_build

if grep -q PLACEHOLDER "$ROOT/config.env"; then
  echo "config.env still has PLACEHOLDER iteration counts: finish pilot p2 first." >&2
  exit 1
fi

MODE="${1:?usage: experiment.sh all | session <k>}"
AXES="${AXES_ONLY:-}"
case "$MODE" in
  all)     DIR="$ROOT/results/main-all"; PLANARGS=(--mode all) ;;
  session) K="${2:?session number 1..$LAUNCHES}"; DIR="$ROOT/results/$(printf 'main-s%02d' "$K")"; PLANARGS=(--mode session --session "$K") ;;
  *)       echo "usage: experiment.sh all | session <k>" >&2; exit 1 ;;
esac
mkdir -p "$DIR"

if [[ ! -f "$DIR/plan.tsv" ]]; then
  "$JAVA" -cp "$ROOT/build" bench.Plan "${PLANARGS[@]}" --launches "$LAUNCHES" --reps "$REPS" --warmup "$WARMUP" \
    --seed "$SEED" ${AXES:+--axes-only "$AXES"} --out "$DIR/plan.tsv"
else
  echo "resuming with existing $DIR/plan.tsv"
fi
exec "$ROOT/scripts/run.sh" "$DIR/plan.tsv" "$DIR"
