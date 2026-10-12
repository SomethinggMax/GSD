#!/usr/bin/env bash
# Checks the machine state before a measurement session. Exit code 1 if any FAIL.
# usage: sudo ./scripts/precheck.sh          (check only)
#        sudo ./scripts/precheck.sh --fix    (also set turbo off, governor, stop update timers, sysctls)
set -uo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root

FIX=0; [[ "${1:-}" == "--fix" ]] && FIX=1
FAILS=0; WARNS=0
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

echo "precheck $(date -Is) on $(hostname)  (fix=$FIX)"

# --- RAPL ---------------------------------------------------------------------------------------
PKG="$(pkg_dir)"
if [[ "$(cat "$PKG/name" 2>/dev/null)" == "package-0" ]] && cat "$PKG/energy_uj" >/dev/null 2>&1; then
  ok "RAPL package domain $PKG readable"
else
  fail "RAPL package domain not found/readable at $PKG (is the intel_rapl_msr module loaded?)"
fi
if D="$(dram_dir)"; then ok "RAPL dram domain: $D"; else warn "no RAPL dram domain: report package energy only"; fi

# --- CPU frequency ------------------------------------------------------------------------------
DRV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo none)
[[ "$DRV" == "intel_pstate" ]] && ok "scaling driver intel_pstate" || warn "scaling driver is '$DRV' (report says intel_pstate)"

NT=/sys/devices/system/cpu/intel_pstate/no_turbo
if [[ -f $NT ]]; then
  if [[ "$(cat $NT)" != "1" && $FIX -eq 1 ]]; then save_orig no_turbo "$(cat $NT)"; echo 1 >$NT; fi
  [[ "$(cat $NT)" == "1" ]] && ok "turbo boost off (no_turbo=1)" || fail "turbo boost is ON (run with --fix)"
else
  fail "$NT missing: cannot verify turbo boost is off"
fi

BADGOV=0
for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
  if [[ "$(cat "$g")" != "$EXPECTED_GOVERNOR" ]]; then
    if [[ $FIX -eq 1 ]]; then save_orig governor "$(cat "$g")"; echo "$EXPECTED_GOVERNOR" >"$g"; fi
    [[ "$(cat "$g")" != "$EXPECTED_GOVERNOR" ]] && BADGOV=1
  fi
done
[[ $BADGOV -eq 0 ]] && ok "governor $EXPECTED_GOVERNOR on all CPUs" || fail "governor differs from $EXPECTED_GOVERNOR (run with --fix)"

NCPU=$(nproc)
[[ "$NCPU" == "$CORES" ]] && ok "$NCPU CPUs online" || warn "$NCPU CPUs online, config says CORES=$CORES"

# --- Java ---------------------------------------------------------------------------------------
JV=$("$JAVA" -version 2>&1 | grep -v JAVA_TOOL_OPTIONS | head -1)
if [[ -z "$EXPECTED_JAVA" || "$JV" == *"$EXPECTED_JAVA"* ]]; then ok "java: $JV"; else warn "java is '$JV', expected '$EXPECTED_JAVA'"; fi

# --- Background activity ------------------------------------------------------------------------
for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    [[ $FIX -eq 1 ]] && save_orig "unit.$u" active && systemctl stop "$u"
    systemctl is-active --quiet "$u" && fail "$u is active (run with --fix)" || ok "$u stopped"
  else
    ok "$u not active"
  fi
done
for u in fwupd-refresh.timer motd-news.timer man-db.timer; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    [[ $FIX -eq 1 ]] && save_orig "unit.$u" active && systemctl stop "$u"
    systemctl is-active --quiet "$u" && warn "$u is active" || ok "$u stopped"
  fi
done
if command -v snap >/dev/null; then
  if snap refresh --time 2>/dev/null | grep -q '^hold:'; then ok "snap refreshes on hold"
  elif [[ $FIX -eq 1 ]]; then save_orig snap_hold 1; snap refresh --hold=72h >/dev/null 2>&1 && ok "snap refreshes held for 72 h" || warn "could not hold snap refreshes"
  else warn "snap refreshes not on hold (run with --fix)"; fi
fi
if [[ "$(systemctl is-enabled sleep.target 2>/dev/null)" == "masked" ]]; then ok "suspend disabled (sleep.target masked)"
else
  [[ $FIX -eq 1 ]] && save_orig sleep_masked 1 && systemctl mask $SLEEP_UNITS >/dev/null 2>&1
  [[ "$(systemctl is-enabled sleep.target 2>/dev/null)" == "masked" ]] && ok "suspend disabled" || warn "suspend not disabled"
fi

if pgrep -f 'bench\.(Bench|Calib)' >/dev/null; then fail "another benchmark JVM is running"; else ok "no other benchmark JVM running"; fi
LOAD=$(cut -d' ' -f1 /proc/loadavg)
awk -v l="$LOAD" 'BEGIN { exit !(l < 0.5) }' && ok "load average $LOAD" || warn "load average $LOAD (machine not idle?)"
echo "  INFO  logged in: $(who | awk '{print $1}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"

# --- Limits for benchmark C (10,000 simultaneous connections) -----------------------------------
for k in net.core.somaxconn net.ipv4.tcp_max_syn_backlog; do
  v=$(sysctl -n $k 2>/dev/null || echo 0)
  if (( v < 16384 )) && [[ $FIX -eq 1 ]]; then save_orig "sysctl.$k" "$v"; sysctl -qw "$k=16384"; v=$(sysctl -n $k); fi
  (( v >= 16384 )) && ok "$k=$v" || warn "$k=$v (< 16384: SYN drops possible at C=10000, run with --fix)"
done
HN=$(ulimit -Hn)
[[ "$HN" == "unlimited" ]] || (( HN >= 65536 )) && ok "open files hard limit $HN" || warn "open files hard limit $HN (< 65536)"

echo "precheck done: $FAILS FAIL, $WARNS WARN"
[[ $FAILS -eq 0 ]]
