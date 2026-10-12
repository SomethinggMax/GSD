#!/usr/bin/env bash
# After the experiment: undo every system change made by setup-once.sh and precheck.sh --fix
# (turbo, governor, stopped update services/timers, snap hold, masked suspend, sysctls), using the
# original values those scripts recorded in $ORIG. The JDK package hold is left alone on purpose.
# usage: sudo ./scripts/restore.sh
set -uo pipefail
source "$(dirname "$0")/common.sh"
require_root

if [[ -f "$ORIG" ]]; then
  while IFS='=' read -r key val; do
    case "$key" in
      no_turbo)
        echo "$val" >/sys/devices/system/cpu/intel_pstate/no_turbo && echo "turbo restored (no_turbo=$val)" ;;
      governor)
        for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo "$val" >"$g"; done
        echo "governor restored ($val)" ;;
      sysctl.*)
        sysctl -qw "${key#sysctl.}=$val" && echo "${key#sysctl.} restored ($val)" ;;
      unit.*)
        systemctl start "${key#unit.}" && echo "started ${key#unit.}" ;;
      sleep_masked)
        systemctl unmask $SLEEP_UNITS >/dev/null 2>&1 && echo "suspend enabled again" ;;
      snap_hold)
        snap refresh --unhold </dev/null >/dev/null 2>&1 && echo "snap refreshes unheld" ;;
      *)
        echo "unknown entry in $ORIG: $key" >&2 ;;
    esac
  done <"$ORIG"
  mv "$ORIG" "$ORIG.restored-$(date +%Y%m%d-%H%M%S)"
else
  echo "nothing recorded in $ORIG: the scripts changed no settings (or restore already ran)"
fi

if [[ -f /etc/sysctl.d/99-energy-bench.conf ]]; then
  rm /etc/sysctl.d/99-energy-bench.conf && echo "removed /etc/sysctl.d/99-energy-bench.conf"
fi
echo "JDK packages are still held. To release: sudo apt-mark unhold \$(apt-mark showhold | grep openjdk)"
