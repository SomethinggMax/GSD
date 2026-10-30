#!/usr/bin/env bash
# Prints the machine state for the record (stored with every run).
# usage: sudo ./scripts/machine_state.sh > machine_state.txt
source "$(dirname "$0")/common.sh"
load_config

section() { printf '\n===== %s =====\n' "$1"; }

section "time";        date -Is; uptime
section "host";        hostname; uname -a; grep PRETTY_NAME /etc/os-release
section "kernel cmdline"; cat /proc/cmdline
section "cpu";         lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|MHz|NUMA node\(s\)'
section "cpufreq"
echo "driver:    $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)"
echo "governors: $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' ')"
echo "no_turbo:  $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
echo "min/max:   $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null) / $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null) kHz"
echo "EPP:       $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
section "rapl"
for d in "$RAPL_ROOT"/intel-rapl:*; do
  [[ -f "$d/name" ]] && echo "$(basename "$d"): $(cat "$d/name")  max_energy_range_uj=$(cat "$d/max_energy_range_uj" 2>/dev/null)"
done
section "temperature"; for h in /sys/class/hwmon/hwmon*; do
  [[ "$(cat "$h/name" 2>/dev/null)" == coretemp ]] && for t in "$h"/temp*_input; do
    echo "$(cat "${t%_input}_label" 2>/dev/null): $(( $(cat "$t") / 1000 )) C"; done; done
section "memory";      free -m
section "java";        "$JAVA" -version 2>&1 | grep -v JAVA_TOOL_OPTIONS
section "jdk packages"; dpkg -l 'openjdk-*' 2>/dev/null | awk '/^[hi]i/{print $1, $2, $3}'
section "held packages"; apt-mark showhold 2>/dev/null
section "sysctl";      sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog kernel.perf_event_paranoid 2>/dev/null
section "timers";      systemctl list-timers --all --no-pager 2>/dev/null | head -30
section "logged in";   who
section "top processes by cpu"; ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head -15
section "network";     ip -br link 2>/dev/null   # names and state only, no addresses
section "harness";     (cd "$ROOT" && git rev-parse HEAD 2>/dev/null && git status --short 2>/dev/null | head -20) || echo "not a git checkout"
