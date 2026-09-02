#!/bin/zsh

set -u
umask 077

EXPECTED_MARKER="maclagmonitor-install:v1"
ORIGINAL_INSTALL_ROOT="${MLM_INSTALL_ROOT:-${0:A:h}}"

if [[ "${1:-}" != "--from-temp" ]]; then
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/maclagmonitor-uninstall.XXXXXX")" || exit 1
  TEMP_SCRIPT="$TEMP_DIR/uninstall.command"
  cp "$0" "$TEMP_SCRIPT" || exit 1
  chmod 700 "$TEMP_SCRIPT"
  exec env MLM_INSTALL_ROOT="$ORIGINAL_INSTALL_ROOT" "$TEMP_SCRIPT" --from-temp
fi

cleanup_temp() {
  local temp_parent="${0:A:h}"
  [[ "$temp_parent" == "${TMPDIR:-/tmp}"/maclagmonitor-uninstall.* || "$temp_parent" == /tmp/maclagmonitor-uninstall.* ]] || return
  rm -f -- "$0" 2>/dev/null || true
  rmdir "$temp_parent" 2>/dev/null || true
}
trap cleanup_temp EXIT

INSTALL_ROOT="${MLM_INSTALL_ROOT:-${0:A:h}}"
INSTALL_ROOT="${INSTALL_ROOT:A}"
CONFIG_FILE="${MLM_CONFIG_FILE:-$INSTALL_ROOT/config.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi
LABEL="${MLM_LAUNCHD_LABEL:-${LAUNCHD_LABEL:-com.maclagmonitor.agent}}"
PLIST_PATH="${MLM_LAUNCH_AGENT_PATH:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
MARKER_FILE="$INSTALL_ROOT/.mac-lag-monitor-install"
MONITOR="$INSTALL_ROOT/bin/mac-lag-monitor.sh"

case "$INSTALL_ROOT" in
  /|"$HOME"|"$HOME/Library"|"$HOME/Library/Application Support")
    print -u2 -- "Refusing to uninstall from an unsafe directory: $INSTALL_ROOT"
    exit 1
    ;;
esac

if [[ ! -f "$MARKER_FILE" || "$(<"$MARKER_FILE")" != "$EXPECTED_MARKER" ]]; then
  print -u2 -- "MacLagMonitor install marker was not found. Nothing was deleted."
  exit 1
fi

if [[ ! -f "$MONITOR" || ! -f "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh" ]]; then
  print -u2 -- "Expected MacLagMonitor executables are missing. Nothing was deleted."
  exit 1
fi

if [[ -f "$PLIST_PATH" ]]; then
  plist_label="$(plutil -extract Label raw "$PLIST_PATH" 2>/dev/null || true)"
  if [[ "$plist_label" != "$LABEL" ]]; then
    print -u2 -- "LaunchAgent label mismatch. Nothing was deleted: $PLIST_PATH"
    exit 1
  fi
fi

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true

if [[ -f "$INSTALL_ROOT/state/monitor.pid" ]]; then
  pid="$(<"$INSTALL_ROOT/state/monitor.pid")"
  if [[ "$pid" == <-> ]]; then
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"$MONITOR"* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi
fi

[[ -f "$PLIST_PATH" ]] && rm -f -- "$PLIST_PATH"
find "$INSTALL_ROOT" -depth -delete 2>/dev/null

leftovers=0
[[ -e "$INSTALL_ROOT" ]] && { print -u2 -- "Remaining install path: $INSTALL_ROOT"; leftovers=1; }
[[ -e "$PLIST_PATH" ]] && { print -u2 -- "Remaining LaunchAgent: $PLIST_PATH"; leftovers=1; }

if (( leftovers == 0 )); then
  print -r -- "MacLagMonitor and its local runtime data were removed."
  print -r -- "macOS unified logs, APFS snapshots, and backups are managed separately by macOS."
else
  print -u2 -- "Some files could not be removed. Review the paths above."
  exit 1
fi
