#!/usr/bin/env bash
# Runs the whole study unattended: precheck, pilots p1-p5, the main experiment, then restore.sh.
# It runs as a systemd service, so no SSH session is needed, and it continues after a reboot:
# precheck --fix switches turbo off again, finished steps are skipped, and p3, p4 and the main
# experiment resume where they stopped (p1, p2 and p5 are short and start over).
#
#   sudo ./scripts/all.sh install [--until p1|p2|p3|p4|p5|main] [--at "2026-10-14 21:00"]
#                                   install and start (default: until main, now); --at delays the start.
#                                   The machine clock is UTC: write Dutch time with its zone, "2026-10-14 21:00 CEST"
#   ./scripts/all.sh status                                         progress, no sudo needed
#   sudo ./scripts/all.sh uninstall                                 stop and remove the service
#
# Before measuring, it waits until nobody is logged in and the VS Code server has exited, so you
# start it, log out, and close VS Code.
#
# Decisions that are otherwise made by hand (README section 2):
#   after p2  ITERS_A and ITERS_B are written to config.env; stops if Calib reports FAIL
#   after p3  stops if failures.csv is not empty
#   after p4  none: the main experiment uses LAUNCHES / REPS / WARMUP from config.env
# Log: results/all/all.log. Outcome: results/all/FINISHED or results/all/FAILED (with the reason).
set -uo pipefail
source "$(dirname "$0")/common.sh"
load_config

UNIT=energy-bench
UNIT_FILE=/etc/systemd/system/$UNIT.service
STATE="$ROOT/results/all"
LOG="$STATE/all.log"
STEPS=(p1 p2 p3 p4 p5 main)
IDLE_WAIT_MIN=5   # nobody logged in and no VS Code server for this many minutes before starting

log() { echo "$(date '+%F %T') $*"; }

# Results are written as root; give them back to the owner of the checkout.
give_back_results() {
  local owner
  owner=$(stat -c %U "$ROOT/config.env")
  chown -R "$owner:$(id -gn "$owner")" "$ROOT/results" 2>/dev/null || true
}

finish() {
  "$ROOT/scripts/restore.sh"
  systemctl disable "$UNIT" >/dev/null 2>&1   # do not start again after the next reboot
  give_back_results
}

fail() {
  log "FAILED: $*"
  echo "$(date -Is) $*" >"$STATE/FAILED"
  finish
  exit 1
}

wait_for_idle() {
  local quiet=0 waited=0 users vscode
  while ((quiet < IDLE_WAIT_MIN)); do
    users=$(who | wc -l)
    vscode=$(pgrep -fc '\.vscode-server/cli/servers/' || true)
    if ((users == 0 && vscode == 0)); then
      quiet=$((quiet + 1))
    else
      quiet=0
      ((waited % 10 == 0)) && log "waiting: $users login session(s), $vscode VS Code server process(es)"
    fi
    sleep 60
    waited=$((waited + 1))
  done
  log "machine idle for $IDLE_WAIT_MIN min, starting"
}

# Replaces "KEY=..." in config.env, keeping the file's owner (no sed -i, which would make it root's).
set_config() {
  local tmp
  tmp=$(mktemp)
  sed -E "s|^$1=.*|$1=$2   # calibrated by pilot p2 on $(date -I)|" "$ROOT/config.env" >"$tmp" && cat "$tmp" >"$ROOT/config.env"
  rm -f "$tmp"
}

apply_calibration() {
  local bm f v
  for bm in A B; do
    f="$ROOT/results/pilot/p2/k_$bm.txt"
    grep -q '^OK ' "$f" 2>/dev/null || fail "calibration of $bm did not pass the 8-thread check, see $f"
    v=$(grep -oE "ITERS_$bm=[0-9]+" "$f" | tail -1 | cut -d= -f2)
    [[ -n "$v" ]] || fail "no ITERS_$bm found in $f"
    set_config "ITERS_$bm" "$v"
    log "config.env: ITERS_$bm=$v"
  done
  grep -q PLACEHOLDER "$ROOT/config.env" && fail "config.env still contains PLACEHOLDER"
  log "remember to commit config.env (calibrated values)"
}

run_step() {
  local step="$1" dir="$ROOT/results/pilot/$1"
  case "$step" in
    p1 | p2 | p5)
      # Not resumable: keep an earlier (partial) attempt aside and start clean.
      [[ -e "$dir" ]] && mv "$dir" "$dir.previous-$(date +%Y%m%d-%H%M%S)"
      "$ROOT/scripts/pilot.sh" "$step" || fail "pilot $step exited with an error"
      [[ "$step" == p2 ]] && apply_calibration
      ;;
    p3 | p4)
      "$ROOT/scripts/pilot.sh" "$step" || fail "pilot $step exited with an error"
      if [[ -s "$dir/failures.csv" ]]; then
        [[ "$step" == p3 ]] && fail "pilot p3 has failed launches, see $dir/failures.csv"
        log "WARN: pilot p4 has failed launches, see $dir/failures.csv"
      fi
      ;;
    main)
      "$ROOT/scripts/experiment.sh" all || fail "main experiment exited with an error"
      ;;
  esac
}

run() {
  local until="$1" start_at="$2" step
  mkdir -p "$STATE"
  exec > >(tee -a "$LOG") 2>&1
  rm -f "$STATE/FAILED"
  log "==== start (until $until), done so far: $(cd "$STATE" && ls -- *.done 2>/dev/null | tr '\n' ' ')"
  # Waiting in the service itself (not a timer) also keeps the start time after a reboot.
  if ((start_at > $(date +%s))); then
    log "scheduled: waiting until $(date -d "@$start_at" '+%F %R')"
    sleep $((start_at - $(date +%s)))
  fi
  wait_for_idle
  "$ROOT/scripts/precheck.sh" --fix || fail "precheck reports FAIL"
  for step in "${STEPS[@]}"; do
    if [[ -f "$STATE/$step.done" ]]; then
      log "$step already done"
    else
      log "---- $step"
      run_step "$step"
      touch "$STATE/$step.done"
      log "---- $step done"
    fi
    [[ "$step" == "$until" ]] && break
  done
  date -Is >"$STATE/FINISHED"
  log "==== finished (until $until)"
  finish
}

install() {
  require_root
  require_build
  local until=main at=0
  while (($#)); do
    case "$1" in
      --until) until="${2:?--until needs a step}"; shift 2 ;;
      --at) at=$(date -d "${2:?--at needs a time}" +%s) || exit 1; shift 2 ;;
      *) echo "unknown option $1" >&2; exit 1 ;;
    esac
  done
  [[ " ${STEPS[*]} " == *" $until "* ]] || { echo "--until must be one of: ${STEPS[*]}" >&2; exit 1; }
  ((at == 0 || at > $(date +%s))) || { echo "--at is in the past" >&2; exit 1; }
  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=energy-bench: pilots and main experiment (until $until)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=$ROOT/scripts/all.sh run $until $at
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$UNIT"
  echo "Installed and started ($UNIT, until $until)."
  ((at)) && echo "Measuring starts at $(date -d "@$at" '+%F %R %Z') = $(TZ=Europe/Amsterdam date -d "@$at" '+%F %R %Z') (Dutch time)."
  echo "It waits until you have logged out and VS Code is closed, then starts measuring."
  echo "Progress later: ./scripts/all.sh status"
}

uninstall() {
  require_root
  systemctl disable --now "$UNIT" 2>/dev/null
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  echo "Removed $UNIT. Finished steps stay marked in $STATE; settings: sudo ./scripts/restore.sh"
}

status() {
  echo "service: $(systemctl is-active "$UNIT" 2>/dev/null) / $(systemctl is-enabled "$UNIT" 2>/dev/null)"
  echo "done steps: $(cd "$STATE" 2>/dev/null && ls -- *.done 2>/dev/null | tr '\n' ' ')"
  [[ -f "$STATE/FINISHED" ]] && echo "FINISHED at $(cat "$STATE/FINISHED")"
  [[ -f "$STATE/FAILED" ]] && echo "FAILED: $(cat "$STATE/FAILED")"
  local d
  for d in "$ROOT/results/main-all" "$ROOT/results/pilot/p4" "$ROOT/results/pilot/p3"; do
    if [[ -f "$d/plan.tsv" ]]; then echo; "$ROOT/scripts/status.sh" "$d"; break; fi
  done
  echo; echo "last log lines:"; tail -n 8 "$LOG" 2>/dev/null | sed 's/^/  /'
}

case "${1:-}" in
  install) shift; install "$@" ;;
  uninstall) uninstall ;;
  status) status ;;
  run) require_root; require_build; run "${2:-main}" "${3:-0}" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
