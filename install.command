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
  "$PACKAGE_DIR/bin/maclagmonitor-native.swift"
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

if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  print -u2 -- "Building from source requires Apple's Command Line Tools. Run: xcode-select --install"
  exit 1
fi
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/maclagmonitor-build.XXXXXX")" || exit 1
trap 'rm -rf -- "$BUILD_DIR"' EXIT
/usr/bin/swiftc -O "$PACKAGE_DIR/bin/maclagmonitor-native.swift" -o "$BUILD_DIR/maclagmonitor-native" -lsqlite3 -framework CoreGraphics -framework SystemConfiguration || exit 1

mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/data/incidents" "$INSTALL_ROOT/state" "$INSTALL_ROOT/logs" "$LAUNCH_AGENTS_DIR"
cp -f "$PACKAGE_DIR/bin/mac-lag-monitor.sh" "$INSTALL_ROOT/bin/mac-lag-monitor.sh"
cp -f "$PACKAGE_DIR/bin/mac-lag-monitorctl.sh" "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh"
cp -f "$BUILD_DIR/maclagmonitor-native" "$INSTALL_ROOT/bin/maclagmonitor-native"
cp -f "$PACKAGE_DIR/uninstall.command" "$INSTALL_ROOT/uninstall.command"
cp -f "$PACKAGE_DIR/README.md" "$INSTALL_ROOT/README.md"
cp -f "$PACKAGE_DIR/CHANGELOG.md" "$INSTALL_ROOT/CHANGELOG.md"
cp -f "$PACKAGE_DIR/VERSION" "$INSTALL_ROOT/VERSION"

# Keep the installed configuration and all runtime data; never copy a source
# checkout's state into an already installed service.
CONFIG_FILE="$INSTALL_ROOT/config.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$PACKAGE_DIR/config.example.conf" "$CONFIG_FILE"
else
  # Migrate only removed/renamed settings; preserve explicit user intervals.
  if grep -Eq '^[[:space:]]*(MAX_INCIDENT_COUNT|SUMMARY_SIZE_LIMIT_MB|SUMMARY_LEGACY_RETENTION_DAYS|SUMMARY_LEGACY_SIZE_LIMIT_MB)=' "$CONFIG_FILE"; then
    awk '
      FNR==NR {if($0~/^[[:space:]]*HISTORY_RETENTION_DAYS=/) days=1; if($0~/^[[:space:]]*HISTORY_SIZE_LIMIT_MB=/) size=1; next}
      /^[[:space:]]*(MAX_INCIDENT_COUNT|SUMMARY_SIZE_LIMIT_MB)=/ {next}
      /^[[:space:]]*SUMMARY_LEGACY_RETENTION_DAYS=/ {if(days) next;sub(/SUMMARY_LEGACY_RETENTION_DAYS/,"HISTORY_RETENTION_DAYS")}
      /^[[:space:]]*SUMMARY_LEGACY_SIZE_LIMIT_MB=/ {if(size) next;sub(/SUMMARY_LEGACY_SIZE_LIMIT_MB/,"HISTORY_SIZE_LIMIT_MB")}
      {print}
    ' "$CONFIG_FILE" "$CONFIG_FILE" >| "$BUILD_DIR/config.conf" || exit 1
    mv -f "$BUILD_DIR/config.conf" "$CONFIG_FILE"
  fi
fi
source "$CONFIG_FILE"
LABEL="${MLM_LAUNCHD_LABEL:-${LAUNCHD_LABEL:-com.maclagmonitor.agent}}"
PLIST_PATH="${MLM_LAUNCH_AGENT_PATH:-$LAUNCH_AGENTS_DIR/${LABEL}.plist}"
MARKER_FILE="$INSTALL_ROOT/.mac-lag-monitor-install"

chmod 700 "$INSTALL_ROOT/bin/mac-lag-monitor.sh" "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh" "$INSTALL_ROOT/bin/maclagmonitor-native" "$INSTALL_ROOT/uninstall.command"
chmod 600 "$INSTALL_ROOT/config.conf" "$INSTALL_ROOT/README.md" "$INSTALL_ROOT/CHANGELOG.md" "$INSTALL_ROOT/VERSION"
print -r -- "$EXPECTED_MARKER" >| "$MARKER_FILE"
chmod 600 "$MARKER_FILE"

# A user-local command link needs no administrator access and is removed only
# when it still points at this installation.
CLI_DIR="${MLM_CLI_DIR:-$HOME/.local/bin}"
CLI_LINK="$CLI_DIR/maclagmonitor"
old_link="$(sed -n '3p' "$INSTALL_ROOT/MANIFEST.txt" 2>/dev/null || true)"
if [[ -n "$old_link" && "$old_link" != "$CLI_LINK" && -L "$old_link" && "$(readlink "$old_link")" == "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh" ]]; then
  rm -f -- "$old_link"
fi
if mkdir -p "$CLI_DIR" && { [[ ! -e "$CLI_LINK" && ! -L "$CLI_LINK" ]] || [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh" ]]; }; then
  [[ -L "$CLI_LINK" ]] || ln -s "$INSTALL_ROOT/bin/mac-lag-monitorctl.sh" "$CLI_LINK" || exit 1
else
  print -u2 -- "CLI link not installed (path in use or unavailable); use the full control path."
  CLI_LINK=""
fi
cat >| "$INSTALL_ROOT/MANIFEST.txt" <<MANIFEST
$INSTALL_ROOT
$PLIST_PATH
$CLI_LINK
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
[[ -z "$CLI_LINK" ]] || print -r -- "CLI: $CLI_LINK (add its directory to PATH if needed)"
print -r -- "Uninstall: $INSTALL_ROOT/uninstall.command"
if (( NO_LOAD == 1 )); then
  print -r -- "LaunchAgent loading was skipped (--no-load)."
else
  print -r -- "LaunchAgent is enabled for the current user."
fi
