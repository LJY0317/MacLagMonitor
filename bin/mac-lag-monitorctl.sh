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

usage() {
  print -r -- "MacLagMonitor control"
  print -r -- "Usage: $0 {status|snapshot|test-trigger|start|stop|restart|logs|uninstall}"
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid="$(<"$PID_FILE")"
  [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null
}

case "${1:-}" in
  status)
    if is_running; then
      print -r -- "MacLagMonitor is running (PID $(<"$PID_FILE"))."
    else
      print -r -- "MacLagMonitor is not running."
    fi
    [[ -f "$DATA_DIR/summary.tsv" ]] && tail -n 2 "$DATA_DIR/summary.tsv"
    if [[ -f "$DATA_DIR/network-events.tsv" ]]; then
      print -r -- "Recent internet transitions:"
      tail -n 4 "$DATA_DIR/network-events.tsv"
    fi
    print -r -- "Installed data size: $(du -sh "$INSTALL_ROOT" 2>/dev/null | awk '{print $1}')"
    ;;
  snapshot)
    "$MONITOR" --once
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
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
      launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 1
    "$0" status
    ;;
  stop)
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    if is_running; then
      kill -TERM "$(<"$PID_FILE")" 2>/dev/null || true
    fi
    print -r -- "MacLagMonitor stopped."
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
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
