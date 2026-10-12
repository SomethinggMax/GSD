#!/usr/bin/env bash
# Machine-time budget for the main experiment, from the measured durations of a finished run
# (normally the smoke test, results/pilot/p3). Uses, per configuration, the mean duration of one
# repetition and the per-launch overhead (JVM start-up, warm-up of the JIT, checksum precompute),
# then scales to LAUNCHES x REPS. Also lists runs shorter than 2 s and checksum failures.
#
# usage: ./scripts/estimate.sh <run-dir>
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
DIR="${1:?usage: estimate.sh <run-dir>}"

awk -v PAUSE="$PAUSE_SEC" -F, '
  FNR == 1 { file++ }
  file == 1 && FNR > 1 {              # launches.csv: launch_id,exit_code,start_epoch_ms,duration_ms
    dt[$1] = $4 / 1000; next
  }
  file == 2 && FNR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
  file == 2 {
    id = $col["launch_id"]; key = id; sub(/-L[0-9]+$/, "", key)
    t = $col["time_ns"] / 1e9
    sum[id] += t; n[id]++; cfg[id] = key
    bench[key] = $col["benchmark"]; bb[key] = $col["b"] + 0; cc[key] = $col["C"] + 0
    if (t < 2) short[key] = short[key] sprintf(" %.2fs", t)
    if ($col["checksum_ok"] != "1") bad[key]++
  }
  END {
    for (id in sum) {
      k = cfg[id]; rep[k] += sum[id] / n[id]; cnt[k]++
      if (id in dt) { o1 = dt[id] - sum[id]; ov[k] += (o1 > 0 ? o1 : 0); ocnt[k]++ }
    }
    nk = 0
    for (k in rep) { nk++; r = rep[k] / cnt[k]; o = (ocnt[k] ? ov[k] / ocnt[k] : 2); R[k] = r; O[k] = o }
    printf "configurations measured: %d\n\n", nk
    printf "%-9s %-9s %-26s %-26s\n", "launches", "reps", "all benchmarks, full grid", "A full, B and C on the axes"
    split("10 7 5", Ls, " "); split("10 8 6", Rs, " ")
    for (i = 1; i <= 3; i++) for (j = 1; j <= 3; j++) {
      full = 0; axes = 0
      for (k in R) {
        per = O[k] + Rs[j] * R[k] + PAUSE
        full += per
        if (bench[k] == "A" || cc[k] == 100 || bb[k] == 0) axes += per
      }
      printf "%-9d %-9d %-26s %-26s\n", Ls[i], Rs[j], sprintf("%.1f h", full * Ls[i] / 3600), sprintf("%.1f h", axes * Ls[i] / 3600)
    }
    printf "\nslowest configurations (mean seconds per repetition):\n"
    m = 0; for (k in R) { keys[++m] = k }
    for (a = 1; a <= m; a++) for (b2 = a + 1; b2 <= m; b2++) if (R[keys[b2]] > R[keys[a]]) { t2 = keys[a]; keys[a] = keys[b2]; keys[b2] = t2 }
    for (a = 1; a <= (m < 10 ? m : 10); a++) printf "  %-24s %7.2f s/rep  overhead %5.1f s/launch\n", keys[a], R[keys[a]], O[keys[a]]
    printf "\nruns shorter than 2 s:\n"; s = 0; for (k in short) { printf "  %-24s%s\n", k, short[k]; s++ }; if (!s) print "  none"
    printf "\nchecksum failures:\n"; s = 0; for (k in bad) { printf "  %-24s %d\n", k, bad[k]; s++ }; if (!s) print "  none"
  }
' "$DIR/launches.csv" "$DIR/results.csv"
