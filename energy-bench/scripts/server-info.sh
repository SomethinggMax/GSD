#!/usr/bin/env bash
# Collects hardware and software details of the experiment machine.
# Read-only: it changes nothing on the system.
# Usage: bash scripts/server-info.sh [out.txt]   (prints and saves, default ./server-info.txt)

out="${1:-server-info.txt}"

section() { echo; echo "== $1"; }

{
  echo "Collected: $(date -Is) on $(hostname)"

  section "CPU"
  lscpu | grep -E "Vendor ID|Model name|Socket|Core|Thread|^CPU\(s\)|NUMA node\(s\)|MHz"

  section "Virtualisation (none = bare metal)"
  systemd-detect-virt

  section "Memory"
  free -h | head -2

  section "OS and kernel"
  grep PRETTY_NAME /etc/os-release
  uname -r

  section "Java"
  if command -v java >/dev/null; then
    java -version
    java -XX:+PrintFlagsFinal -version 2>/dev/null \
      | grep -E " (UseG1GC|UseParallelGC|UseZGC|UseSerialGC|UseShenandoahGC|MaxHeapSize|InitialHeapSize) "
  else
    echo "java not found on PATH"
  fi
  ls -d /usr/lib/jvm/* 2>/dev/null

  section "Frequency governor and driver"
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver

  section "Turbo boost"
  if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo "intel_pstate no_turbo = $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)  (1 = turbo off)"
  elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    echo "cpufreq boost = $(cat /sys/devices/system/cpu/cpufreq/boost)  (1 = boost on)"
  else
    echo "no turbo/boost control file found"
  fi

  section "SMT / hyper-threading"
  cat /sys/devices/system/cpu/smt/control

  section "RAPL domains (powercap)"
  found=0
  for d in /sys/class/powercap/*; do
    if [ -f "$d/name" ]; then
      found=1
      echo "$d  name=$(cat "$d/name")  max_energy_range_uj=$(cat "$d/max_energy_range_uj" 2>/dev/null)"
    fi
  done
  [ "$found" = 0 ] && echo "no powercap domains found"

  section "RAPL counter permissions"
  ls -l /sys/class/powercap/intel-rapl:0/energy_uj
  if cat /sys/class/powercap/intel-rapl:0/energy_uj >/dev/null 2>&1; then
    echo "readable as $(whoami): yes"
  else
    echo "readable as $(whoami): no"
  fi
  if sudo -n true 2>/dev/null; then
    echo "sudo without password: yes"
  else
    echo "sudo without password: no (may still work with a password)"
  fi

  section "Thread and process limits"
  echo "ulimit -u (max user processes) = $(ulimit -u)"
  echo "kernel.threads-max = $(cat /proc/sys/kernel/threads-max)"
  echo "vm.max_map_count   = $(cat /proc/sys/vm/max_map_count)"

  section "Tools"
  for t in perf taskset; do
    command -v "$t" >/dev/null && echo "$t: $(command -v "$t")" || echo "$t: not installed"
  done

  section "Other users and load"
  who
  uptime
} 2>&1 | tee "$out"

echo
echo "Saved to $out"
