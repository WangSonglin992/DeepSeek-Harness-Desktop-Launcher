#!/usr/bin/env bash
set -eu

state_dir="/tmp/deepseek-harness-desktop-${UID}"
log_dir="${HOME}/.cache/deepseek-harness-launcher"
runtime_dir="${HOME}/.local/share/deepseek-harness-launcher/runtime"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$state_dir" "$log_dir"
chmod 700 "$state_dir" "$log_dir"

is_safe_id() {
  [[ "${1:-}" =~ ^[0-9a-fA-F-]{36}$ ]]
}

state_file_for() {
  printf '%s/%s.state\n' "$state_dir" "$1"
}

group_has_harness() {
  local pgid="$1"
  ps -eo pgid=,args= \
    | awk -v target="$pgid" '$1 == target { $1 = ""; sub(/^ +/, ""); print }' \
    | grep -Eq '(@deepseek-ai/dsh(@latest)?|/node_modules/\.bin/dsh).*web'
}

stop_state_file() {
  local state_file="$1"
  local pid pgid actual_pgid

  if [ ! -f "$state_file" ]; then
    return 0
  fi

  read -r pid pgid < "$state_file" || true
  if ! [[ "${pid:-}" =~ ^[0-9]+$ && "${pgid:-}" =~ ^[0-9]+$ ]]; then
    rm -f -- "$state_file"
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f -- "$state_file"
    return 0
  fi

  actual_pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  if [ "$actual_pgid" != "$pgid" ] || ! group_has_harness "$pgid"; then
    printf 'Refusing to stop unrecognized process group %s from %s\n' "$pgid" "$state_file" >&2
    return 20
  fi

  kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 -- "-$pgid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  if kill -0 -- "-$pgid" 2>/dev/null; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  rm -f -- "$state_file"
}

install_runtime() {
  if ! command -v pnpm >/dev/null 2>&1; then
    printf 'pnpm is required to install DeepSeek Harness.\n' >&2
    return 24
  fi

  mkdir -p "$runtime_dir"
  chmod 700 "$runtime_dir"
  if [ ! -f "$script_dir/pnpm-workspace.yaml" ]; then
    printf 'The pnpm runtime policy is missing next to %s.\n' "$0" >&2
    return 25
  fi
  cp -- "$script_dir/pnpm-workspace.yaml" "$runtime_dir/pnpm-workspace.yaml"
  if [ ! -f "$runtime_dir/package.json" ]; then
    pnpm --dir "$runtime_dir" init >/dev/null
  fi

  PNPM_CONFIG_AUTO_INSTALL_PEERS=true \
    pnpm --dir "$runtime_dir" add --save-exact @deepseek-ai/dsh@latest

  if [ ! -x "$runtime_dir/node_modules/.bin/dsh" ]; then
    printf 'DeepSeek Harness runtime was not installed correctly.\n' >&2
    return 27
  fi
}

start_harness() {
  local launch_id="$1"
  local state_file pid pgid log_file

  if ! is_safe_id "$launch_id"; then
    printf 'Invalid launch id\n' >&2
    return 21
  fi

  state_file=$(state_file_for "$launch_id")
  if [ -e "$state_file" ]; then
    stop_state_file "$state_file"
  fi

  pid="$$"
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  if [ "$pid" != "$pgid" ]; then
    printf 'Launcher must run in its own process group (pid=%s pgid=%s)\n' "$pid" "$pgid" >&2
    return 22
  fi

  umask 077
  printf '%s %s\n' "$pid" "$pgid" > "$state_file"
  log_file="$log_dir/latest.log"
  : > "$log_file"

  cleanup() {
    rm -f -- "$state_file"
  }
  trap cleanup EXIT

  if [ ! -x "$runtime_dir/node_modules/.bin/dsh" ]; then
    printf 'DeepSeek Harness runtime is missing. Run Install.ps1 again.\n' >&2
    return 26
  fi

  export BROWSER=none
  "$runtime_dir/node_modules/.bin/dsh" web --no-open >> "$log_file" 2>&1
}

stop_launch() {
  local launch_id="$1"
  if ! is_safe_id "$launch_id"; then
    printf 'Invalid launch id\n' >&2
    return 23
  fi
  stop_state_file "$(state_file_for "$launch_id")"
}

stop_all() {
  local state_file
  for state_file in "$state_dir"/*.state; do
    [ -e "$state_file" ] || continue
    stop_state_file "$state_file"
  done
}

case "${1:-}" in
  install)
    install_runtime
    ;;
  start)
    start_harness "${2:-}"
    ;;
  stop)
    stop_launch "${2:-}"
    ;;
  stop-all)
    stop_all
    ;;
  *)
    printf 'Usage: %s {install|start <launch-id>|stop <launch-id>|stop-all}\n' "$0" >&2
    exit 2
    ;;
esac
