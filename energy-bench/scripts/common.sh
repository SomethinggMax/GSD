# shellcheck shell=bash
# Shared helpers, sourced by the other scripts.
# Values from config.env can be overridden per command: LAUNCHES=5 sudo -E ./scripts/experiment.sh all

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_config() {
  local v
  local vars
  vars=$(grep -oE '^[A-Z_]+=' "$ROOT/config.env" | tr -d '=')
  for v in $vars; do
    if [[ -n "${!v+x}" ]]; then eval "__override_$v=\"\${$v}\""; fi
  done
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  for v in $vars; do
    local o="__override_$v"
    if [[ -n "${!o+x}" ]]; then eval "$v=\"\${$o}\""; fi
  done
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo (RAPL energy_uj and the power settings are root-only)." >&2
    exit 1
  fi
}

require_build() {
  if [[ ! -f "$ROOT/build/bench/Bench.class" ]]; then
    echo "Not built yet: run ./build.sh first." >&2
    exit 1
  fi
}

pkg_dir() { echo "$RAPL_ROOT/intel-rapl:0"; }

dram_dir() {
  local d
  for d in "$RAPL_ROOT"/intel-rapl:0/intel-rapl:0:*; do
    if [[ -f "$d/name" && "$(cat "$d/name")" == "dram" ]]; then echo "$d"; return 0; fi
  done
  return 1
}

# Original system settings, recorded before setup-once.sh / precheck.sh --fix first change them,
# so restore.sh can put back exactly what was there. One "key=value" per line; only the first value counts.
STATE_DIR=/var/lib/energy-bench
ORIG="$STATE_DIR/original-settings.env"

save_orig() {
  mkdir -p "$STATE_DIR"
  grep -q "^$1=" "$ORIG" 2>/dev/null || echo "$1=$2" >>"$ORIG"
}

SLEEP_UNITS="sleep.target suspend.target hibernate.target hybrid-sleep.target"

# Give the files back to the user who called sudo, so they can read/copy them without sudo.
give_back() {
  if [[ -n "${SUDO_USER:-}" ]]; then chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$@" 2>/dev/null || true; fi
}

# Start the echo server for benchmark C in the background; sets SERVER_PID. Log goes to $1.
start_echo_server() {
  local log="$1"
  "$JAVA" $SERVER_JVM_FLAGS -cp "$ROOT/build" bench.EchoServer "$PORT" >"$log" 2>&1 </dev/null &
  SERVER_PID=$!
  local _
  for _ in $(seq 1 100); do
    if grep -q READY "$log" 2>/dev/null; then return 0; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 0.1
  done
  echo "Echo server did not start, see $log" >&2
  cat "$log" >&2
  return 1
}

stop_echo_server() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}
