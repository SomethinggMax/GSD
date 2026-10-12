#!/usr/bin/env bash
# One-time preparation of the measurement machine (persistent settings). Safe to run twice.
# usage: sudo ./scripts/setup-once.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
require_root

echo "== never suspend (the machine must stay up during multi-day runs)"
[[ "$(systemctl is-enabled sleep.target 2>/dev/null)" == "masked" ]] || save_orig sleep_masked 1
systemctl mask $SLEEP_UNITS

echo "== listen backlog for 10,000 simultaneous local connections (benchmark C)"
for k in net.core.somaxconn net.ipv4.tcp_max_syn_backlog; do save_orig "sysctl.$k" "$(sysctl -n $k)"; done
cat >/etc/sysctl.d/99-energy-bench.conf <<'CONF'
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
CONF
sysctl --system >/dev/null

echo "== hold the JDK packages at the current version for the whole experiment"
PKGS=$(dpkg -l 'openjdk-25*' 2>/dev/null | awk '/^ii/{print $2}')
if [[ -n "$PKGS" ]]; then apt-mark hold $PKGS; else echo "no openjdk-25 packages found (install: sudo apt install openjdk-25-jdk-headless)"; fi

echo "== tools used by the scripts"
for t in timeout awk systemd-run; do command -v "$t" >/dev/null || echo "missing: $t"; done
echo "done. Per session, scripts/precheck.sh --fix sets turbo off and stops the update timers."
echo "Original settings are recorded in $ORIG; scripts/restore.sh puts them back after the experiment."
