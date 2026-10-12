#!/usr/bin/env bash
# Quick look at a running or finished run. Cheap: reads a few files, safe to use during measurements.
# usage: ./scripts/status.sh <run-dir>
DIR="${1:?usage: status.sh <run-dir>}"
TOTAL=$(($(wc -l <"$DIR/plan.tsv") - 1))
DONE=$(wc -l <"$DIR/done.txt" 2>/dev/null || echo 0)
FAILED=0; [[ -f "$DIR/failures.csv" ]] && FAILED=$(($(wc -l <"$DIR/failures.csv") - 1))
echo "$DIR: $DONE/$TOTAL launches done, $FAILED failed"
if pgrep -f "bench.Bench.*$(basename "$DIR")" >/dev/null; then
  echo "running now: $(pgrep -af 'bench.Bench' | grep -o -- '--launch-id [^ ]*' | head -1)"
else
  echo "no launch running right now"
fi
echo "last progress lines:"; tail -n 5 "$DIR/progress.log" 2>/dev/null | sed 's/^/  /'
[[ $FAILED -gt 0 ]] && { echo "failures:"; tail -n 5 "$DIR/failures.csv" | sed 's/^/  /'; }
[[ -f "$DIR/idle.csv" ]] && { echo "idle power windows:"; tail -n 3 "$DIR/idle.csv" | sed 's/^/  /'; }
for h in /sys/class/hwmon/hwmon*; do
  [[ "$(cat "$h/name" 2>/dev/null)" == coretemp ]] && echo "package temperature now: $(( $(cat "$h/temp1_input") / 1000 )) C"
done
exit 0
