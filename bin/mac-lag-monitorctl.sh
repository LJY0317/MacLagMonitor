#!/bin/zsh

set -u
umask 077

SCRIPT_DIR="${0:A:h}"
INSTALL_ROOT="${MLM_INSTALL_ROOT:-${SCRIPT_DIR:h}}"
STATE_DIR="$INSTALL_ROOT/state"
DATA_DIR="$INSTALL_ROOT/data"
PID_FILE="$STATE_DIR/monitor.pid"
CONFIG_FILE="${MLM_CONFIG_FILE:-$INSTALL_ROOT/config.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi
LABEL="${MLM_LAUNCHD_LABEL:-${LAUNCHD_LABEL:-com.maclagmonitor.agent}}"
PLIST_PATH="${MLM_LAUNCH_AGENT_PATH:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
MONITOR="$INSTALL_ROOT/bin/mac-lag-monitor.sh"
NATIVE="$INSTALL_ROOT/bin/maclagmonitor-native"

usage() {
  cat <<'HELP'
MacLagMonitor
Usage: maclagmonitor <command> [options]

Read-only:
  status [--json]             Installed version, process, settings, recent detection
  sources [--last 7d] [--json]
  query <power|battery|sleep|cpu|memory|network|incidents|timeline|history|logs|reports>
        [--last 24h | --from ISO8601 --to ISO8601]
        [--group-by hour|day] [--limit N] [--json]
        [--events]            With sleep only: show retained macOS wake, display and unlock events
  version                     Installed version
  help                        This help

Explicit collection/control:
  snapshot                    Fresh one-shot TSV; no change to live capture state
  diagnose                   Save a one-shot incident
  network                    Save a fresh network diagnostic
  prepare-reboot             Request a before/after network comparison
  test-trigger               Request an explicit incident capture
  start | stop | restart | logs | uninstall
HELP
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid="$(<"$PID_FILE")"
  [[ "$pid" == <-> && "$pid" != 0 ]] && [[ "$(ps -p "$pid" -o command= 2>/dev/null)" == *"$MONITOR"* ]]
}

case "${1:-}" in
  help|-h|--help|'')
    usage
    ;;
  version|--version)
    cat "$INSTALL_ROOT/VERSION"
    ;;
  status)
    shift
    exec "$NATIVE" status "$INSTALL_ROOT" "$@"
    ;;
  sources)
    shift
    exec "$NATIVE" query "$INSTALL_ROOT" sources "$@"
    ;;
  query)
    shift
    [[ "${1:-}" != --help && "${1:-}" != -h ]] || { usage; exit 0; }
    exec "$NATIVE" query "$INSTALL_ROOT" "$@"
    ;;
  snapshot)
    "$MONITOR" --once
    ;;
  network)
    "$MONITOR" --network-diagnostic
    ;;
  diagnose)
    "$MONITOR" --diagnose
    ;;
  prepare-reboot)
    "$MONITOR" --prepare-network-reboot
    ;;
  test-trigger)
    if is_running; then
      kill -USR1 "$(<"$PID_FILE")"
      duration="$(awk -F= '/^INCIDENT_DURATION_SECONDS=/ {print $2; exit}' "$INSTALL_ROOT/config.conf" 2>/dev/null)"
      [[ "$duration" == <-> ]] || duration=240
      print -r -- "Manual trigger requested. The monitor will begin a ${duration}-second incident capture."
    else
      print -u2 -- "Monitor is not running."
      exit 1
    fi
    ;;
  start)
    if ! is_running; then
      launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null ||
        launchctl kickstart "gui/$(id -u)/$LABEL" || exit 1
    fi
    "$0" status
    ;;
  stop)
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || {
      if is_running; then
        print -u2 -- "Unable to stop the LaunchAgent."
        exit 1
      fi
    }
    print -r -- "MacLagMonitor stopped."
    ;;
  restart)
    "$0" stop && "$0" start
    ;;
  logs)
    print -r -- "$DATA_DIR"
    open "$DATA_DIR" 2>/dev/null || true
    ;;
  uninstall)
    exec "$INSTALL_ROOT/uninstall.command"
    ;;
  *)
    usage
    exit 2
    ;;
esac
