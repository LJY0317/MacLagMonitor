#!/bin/zsh

set -u
umask 077

PACKAGE_DIR="${0:A:h}"
INSTALL_ROOT="${MLM_INSTALL_ROOT:-$HOME/Library/Application Support/MacLagMonitor}"
INSTALL_ROOT="${INSTALL_ROOT:A}"
LAUNCH_AGENTS_DIR="${MLM_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
EXPECTED_MARKER="maclagmonitor-install:v1"
NO_LOAD=0
[[ "${1:-}" == "--no-load" ]] && NO_LOAD=1

required=(
  "$PACKAGE_DIR/bin/mac-lag-monitor.sh"
  "$PACKAGE_DIR/bin/mac-lag-monitorctl.sh"
  "$PACKAGE_DIR/config.example.conf"
  "$PACKAGE_DIR/uninstall.command"
  "$PACKAGE_DIR/README.md"
  "$PACKAGE_DIR/CHANGELOG.md"
  "$PACKAGE_DIR/VERSION"
)
for file in "${required[@]}"; do
  if [[ ! -f "$file" ]]; then
    print -u2 -- "Incomplete source package; missing: $file"
    exit 1
  fi
done

case "$INSTALL_ROOT" in
  /|"$HOME"|"$HOME/Library"|"$HOME/Library/Application Support")
    print -u2 -- "Refusing to install into an unsafe directory: $INSTALL_ROOT"
    exit 1
    ;;
esac

mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/data/incidents" "$INSTALL_ROOT/state" "$INSTALL_ROOT/logs" "$LAUNCH_AGENTS_DIR"
cp -f "$PACKAGE_DIR/bin/mac-lag-monitor.sh" "$INSTALL_ROOT/bin/mac-lag-monitor.sh"
cp -f "$PACKAGE_DIR/bin/mac-lag-monitorctl.sh" "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh"
cp -f "$PACKAGE_DIR/uninstall.command" "$INSTALL_ROOT/uninstall.command"
cp -f "$PACKAGE_DIR/README.md" "$INSTALL_ROOT/README.md"
cp -f "$PACKAGE_DIR/CHANGELOG.md" "$INSTALL_ROOT/CHANGELOG.md"
cp -f "$PACKAGE_DIR/VERSION" "$INSTALL_ROOT/VERSION"

# If this source directory was previously used as the live installation, migrate
# its local configuration and runtime history before switching launchd to the
# clean install directory. A normal fresh clone has none of these paths.
if [[ ! -f "$INSTALL_ROOT/config.conf" && -f "$PACKAGE_DIR/config.conf" ]]; then
  cp "$PACKAGE_DIR/config.conf" "$INSTALL_ROOT/config.conf"
elif [[ ! -f "$INSTALL_ROOT/config.conf" ]]; then
  cp "$PACKAGE_DIR/config.example.conf" "$INSTALL_ROOT/config.conf"
fi
for runtime_dir in data logs state; do
  if [[ -d "$PACKAGE_DIR/$runtime_dir" ]]; then
    cp -Rp "$PACKAGE_DIR/$runtime_dir/." "$INSTALL_ROOT/$runtime_dir/"
  fi
done

CONFIG_FILE="$INSTALL_ROOT/config.conf"
source "$CONFIG_FILE"
LABEL="${MLM_LAUNCHD_LABEL:-${LAUNCHD_LABEL:-com.maclagmonitor.agent}}"
PLIST_PATH="${MLM_LAUNCH_AGENT_PATH:-$LAUNCH_AGENTS_DIR/${LABEL}.plist}"
MARKER_FILE="$INSTALL_ROOT/.mac-lag-monitor-install"

chmod 700 "$INSTALL_ROOT/bin/mac-lag-monitor.sh" "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh" "$INSTALL_ROOT/uninstall.command"
chmod 600 "$INSTALL_ROOT/config.conf" "$INSTALL_ROOT/README.md" "$INSTALL_ROOT/CHANGELOG.md" "$INSTALL_ROOT/VERSION"
print -r -- "$EXPECTED_MARKER" >| "$MARKER_FILE"
chmod 600 "$MARKER_FILE"

cat >| "$INSTALL_ROOT/MANIFEST.txt" <<MANIFEST
$INSTALL_ROOT
$PLIST_PATH
MANIFEST
chmod 600 "$INSTALL_ROOT/MANIFEST.txt"

xml_escape() {
  print -r -- "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

escaped_program="$(xml_escape "$INSTALL_ROOT/bin/mac-lag-monitor.sh")"
escaped_stdout="$(xml_escape "$INSTALL_ROOT/logs/launchd-stdout.log")"
escaped_stderr="$(xml_escape "$INSTALL_ROOT/logs/launchd-stderr.log")"

cat >| "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$escaped_program</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$escaped_stdout</string>
  <key>StandardErrorPath</key>
  <string>$escaped_stderr</string>
</dict>
</plist>
PLIST
chmod 600 "$PLIST_PATH"

if ! plutil -lint "$PLIST_PATH" >/dev/null; then
  print -u2 -- "LaunchAgent validation failed: $PLIST_PATH"
  exit 1
fi

if (( NO_LOAD == 0 )); then
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  rm -f -- \
    "$INSTALL_ROOT/state/trigger.count" \
    "$INSTALL_ROOT/state/episode-performance.active" \
    "$INSTALL_ROOT/state/episode-performance.recovery" \
    "$INSTALL_ROOT/state/episode-crash.active" \
    "$INSTALL_ROOT/state/episode-crash.recovery"
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"; then
    print -u2 -- "Files were installed, but the LaunchAgent could not be started."
    print -u2 -- "Run the control script's status command and review logs/launchd-stderr.log."
    exit 1
  fi
fi

print -r -- ""
print -r -- "MacLagMonitor installed."
print -r -- "Install path: $INSTALL_ROOT"
print -r -- "Configuration: $INSTALL_ROOT/config.conf"
print -r -- "Control: $INSTALL_ROOT/bin/mac-lag-monitorctl.sh"
print -r -- "Uninstall: $INSTALL_ROOT/uninstall.command"
if (( NO_LOAD == 1 )); then
  print -r -- "LaunchAgent loading was skipped (--no-load)."
else
  print -r -- "LaunchAgent is enabled for the current user."
fi
