#!/bin/zsh

# MacLagMonitor: low-overhead macOS performance monitor with local diagnostics.
# Diagnostic data is never uploaded; optional HTTPS reachability probes are enabled by default.

set -u
unsetopt BG_NICE 2>/dev/null || true
umask 077

SCRIPT_DIR="${0:A:h}"
INSTALL_ROOT="${MLM_INSTALL_ROOT:-${SCRIPT_DIR:h}}"
CONFIG_FILE="${MLM_CONFIG_FILE:-${INSTALL_ROOT}/config.conf}"
DATA_DIR="${INSTALL_ROOT}/data"
INCIDENTS_DIR="${DATA_DIR}/incidents"
STATE_DIR="${INSTALL_ROOT}/state"
LOG_DIR="${INSTALL_ROOT}/logs"
SUMMARY_FILE="${DATA_DIR}/summary.tsv"
NETWORK_EVENTS_FILE="${DATA_DIR}/network-events.tsv"
SERVICE_LOG="${LOG_DIR}/service.log"
PID_FILE="${STATE_DIR}/monitor.pid"
CURL_BIN="${MLM_CURL_BIN:-/usr/bin/curl}"
PS_BIN="${MLM_PS_BIN:-/bin/ps}"
SAMPLE_BIN="${MLM_SAMPLE_BIN:-/usr/bin/sample}"
LOG_BIN="${MLM_LOG_BIN:-/usr/bin/log}"
DIAGNOSTIC_REPORTS_DIR="${MLM_DIAGNOSTIC_REPORTS_DIR:-$HOME/Library/Logs/DiagnosticReports}"
SYSTEM_DIAGNOSTIC_REPORTS_DIR="${MLM_SYSTEM_DIAGNOSTIC_REPORTS_DIR:-/Library/Logs/DiagnosticReports}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  print -u2 -- "Missing config: $CONFIG_FILE"
  exit 2
fi

source "$CONFIG_FILE"

# Defaults keep upgrades from an older config.conf working without forcing a reset.
: "${INTERNET_CHECK_ENABLED:=1}"
: "${INTERNET_CHECK_PRIMARY_URL:=https://captive.apple.com/hotspot-detect.html}"
: "${INTERNET_CHECK_SECONDARY_URL:=https://cp.cloudflare.com/generate_204}"
: "${INTERNET_CONNECT_TIMEOUT_SECONDS:=2}"
: "${INTERNET_TOTAL_TIMEOUT_SECONDS:=4}"
: "${PROCESS_SAMPLE_SECONDS:=2}"
: "${PROCESS_SAMPLE_MAX_PER_INCIDENT:=2}"
: "${PROCESS_SAMPLE_COOLDOWN_SECONDS:=60}"
: "${PROCESS_SAMPLE_MAX_KB:=256}"
: "${WEBKIT_CPU_SAMPLE_THRESHOLD:=50}"
: "${INCIDENT_MEMORY_FREE_PERCENT_THRESHOLD:=10}"
: "${INCIDENT_COMPRESSOR_MB_THRESHOLD:=14336}"
: "${INCIDENT_SAFARI_GROUP_MB_THRESHOLD:=14336}"
: "${INCIDENT_WEBKIT_PROCESS_MB_THRESHOLD:=8192}"
: "${INCIDENT_WINDOWSERVER_CPU_THRESHOLD:=70}"
: "${INCIDENT_WEBKIT_CPU_THRESHOLD:=80}"
: "${SYSTEM_LOG_CAPTURE_TIMEOUT_SECONDS:=8}"
: "${SYSTEM_LOG_TEMP_MAX_MB:=8}"
: "${SYSTEM_LOG_OUTPUT_MAX_MB:=2}"
: "${PERFORMANCE_EPISODE_RECOVERY_SAMPLES:=3}"
: "${REPORTCRASH_CPU_THRESHOLD:=30}"
: "${CORESYMBOLICATION_CPU_THRESHOLD:=15}"
: "${MEDIAANALYSISD_CPU_THRESHOLD:=100}"
: "${MOBILEASSETD_CPU_THRESHOLD:=80}"
: "${REPLAYD_CPU_THRESHOLD:=40}"
: "${SYSTEM_LOAD_PER_LOGICAL_CPU_THRESHOLD:=2}"
: "${SAMPLE_STALL_TRIGGER_SECONDS:=10}"
: "${SAFARI_DIAGNOSTICS_ENABLED:=1}"
: "${SAFARI_FAULT_EXTRACT_MAX_KB:=256}"
: "${SAFARI_FAULT_MAX_REPORTS:=2}"
: "${STORAGE_MAINTENANCE_INTERVAL_SECONDS:=21600}"
: "${LAUNCHD_LOG_SIZE_LIMIT_MB:=2}"
: "${MACOS_RESOURCE_REPORT_MAX_FILES:=3}"
: "${REBOOT_POSTMORTEM_ROWS:=40}"
: "${DOMAIN_CORRELATION_MAX_INCIDENTS:=10}"
: "${DOMAIN_CORRELATION_MIN_REPEAT:=2}"
: "${DOMAIN_CORRELATION_TOP_RESULTS:=5}"
: "${AUX_APP_1_PROCESS_REGEX:=}"
: "${AUX_APP_2_PROCESS_REGEX:=}"
: "${CONTENT_FILTER_PROCESS_REGEX:=}"
: "${CONTENT_FILTER_LOG_DIR:=}"

mkdir -p "$DATA_DIR" "$INCIDENTS_DIR" "$STATE_DIR" "$LOG_DIR"

FORCE_TRIGGER=0
STOP_REQUESTED=0
CURRENT_INCIDENT_DIR=""
CONTEXT_FLAGS=""
TRIGGER_FLAGS=""
SLEEP_PID=0
LOG_CAPTURE_PID=0
OWNS_PID_FILE=0
MACOS_RESOURCE_FOUND=0
MACOS_WEBKIT_RESOURCE_FOUND=0
MACOS_RESOURCE_REPORT_PATH=""
MACOS_RESOURCE_COMMAND=""
MACOS_RESOURCE_PID=""
MACOS_RESOURCE_CPU=""
MACOS_RESOURCE_FOOTPRINT=""
MACOS_RESOURCE_STACK_HINT=""
DOMAIN_CORRELATION_FOUND=0
DOMAIN_CORRELATION_TOP_DOMAIN=""
DOMAIN_CORRELATION_TOP_COUNT=0
DOMAIN_CORRELATION_TOP_HOT_COUNT=0
DOMAIN_CORRELATION_TOP_ACTIVE_COUNT=0
DOMAIN_CORRELATION_INCIDENTS_WITH_DOMAINS=0
DOMAIN_CORRELATION_STRENGTH="none"
LOGICAL_CPU_COUNT="$(sysctl -n hw.logicalcpu_max 2>/dev/null || print 8)"
[[ "$LOGICAL_CPU_COUNT" == <-> ]] || LOGICAL_CPU_COUNT=8

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
epoch_now() { date '+%s'; }

log_message() {
  print -r -- "$(timestamp)"$'\t'"$*" >> "$SERVICE_LOG"
}

handle_manual_trigger() {
  FORCE_TRIGGER=1
  if (( SLEEP_PID > 0 )); then
    kill -TERM "$SLEEP_PID" 2>/dev/null || true
  fi
}

interruptible_sleep() {
  local seconds="$1"
  sleep "$seconds" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=0
}

cleanup_runtime_temp_files() {
  rm -f -- \
    "$STATE_DIR/.internet-primary.$$" "$STATE_DIR/.internet-secondary.$$" \
    "$SUMMARY_FILE.trim.$$" "$SUMMARY_FILE.body.$$" \
    "$NETWORK_EVENTS_FILE.trim.$$" "$NETWORK_EVENTS_FILE.body.$$" 2>/dev/null || true
  if [[ -n "$CURRENT_INCIDENT_DIR" && "$CURRENT_INCIDENT_DIR" == "$INCIDENTS_DIR"/* ]]; then
    rm -f -- \
      "$CURRENT_INCIDENT_DIR/.system-log.tmp" \
      "$CURRENT_INCIDENT_DIR/.safari-fault-summary.tmp" \
      "$CURRENT_INCIDENT_DIR/.content-filter-context.tmp" \
      "$CURRENT_INCIDENT_DIR/.unicorn-context.tmp" 2>/dev/null || true
  fi
  find "$DATA_DIR" "$LOG_DIR" -type f \
    \( -name "*.trim.$$" -o -name "*.body.$$" \) -delete 2>/dev/null || true
}

cleanup_stale_runtime_temp_files() {
  # SIGKILL or a sudden power loss can bypass traps. Remove only monitor-owned
  # temp patterns after a generous age threshold; active captures finish within seconds.
  find "$STATE_DIR" -maxdepth 1 -type f \
    \( -name '.internet-primary.*' -o -name '.internet-secondary.*' \) \
    -mmin +10 -delete 2>/dev/null || true
  find "$DATA_DIR" "$LOG_DIR" -type f \
    \( -name '*.trim.*' -o -name '*.body.*' -o -name '.system-log.tmp' \
       -o -name '.safari-fault-summary.tmp' -o -name '.content-filter-context.tmp' \
       -o -name '.unicorn-context.tmp' \) \
    -mmin +60 -delete 2>/dev/null || true
}

cleanup() {
  STOP_REQUESTED=1
  if (( LOG_CAPTURE_PID > 0 )); then
    kill -TERM "$LOG_CAPTURE_PID" 2>/dev/null || true
    wait "$LOG_CAPTURE_PID" 2>/dev/null || true
    LOG_CAPTURE_PID=0
  fi
  if (( SLEEP_PID > 0 )); then
    kill -TERM "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=0
  fi
  cleanup_runtime_temp_files
  if (( OWNS_PID_FILE == 1 )) && [[ -f "$PID_FILE" ]] && [[ "$(<"$PID_FILE")" == "$$" ]]; then
    rm -f -- "$PID_FILE"
  fi
}

cleanup_stale_runtime_temp_files
trap 'handle_manual_trigger' USR1
trap 'cleanup; exit 0' INT TERM HUP
trap 'cleanup' EXIT

integer_value() {
  local value="${1:-0}"
  value="${value%%.*}"
  [[ "$value" == <-> ]] || value=0
  print -r -- "$value"
}

mb_from_kb() {
  local kb="${1:-0}"
  [[ "$kb" == <-> ]] || kb=0
  printf '%.1f\n' "$(( kb / 1024.0 ))"
}

current_power_mode() {
  local batt
  batt="$(pmset -g batt 2>/dev/null)"
  if [[ "$batt" == *"AC Power"* ]]; then
    print -r -- "AC"
  else
    print -r -- "BATTERY"
  fi
}

low_power_enabled() {
  local value
  value="$(pmset -g 2>/dev/null | awk '/lowpowermode/ {print $2; exit}')"
  [[ "$value" == "1" ]]
}

display_is_off() {
  local state
  state="$(ioreg -r -n IODisplayWrangler -d 1 2>/dev/null | awk -F'= ' '/CurrentPowerState/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
  [[ -n "$state" && "$state" -lt 4 ]]
}

choose_interval() {
  local power="$1"
  if low_power_enabled; then
    print -r -- "$LOW_POWER_INTERVAL_SECONDS"
  elif display_is_off; then
    print -r -- "$DISPLAY_OFF_INTERVAL_SECONDS"
  elif [[ "$power" == "AC" ]]; then
    print -r -- "$AC_INTERVAL_SECONDS"
  else
    print -r -- "$BATTERY_INTERVAL_SECONDS"
  fi
}

update_network_state_if_due() {
  local now last=0 network_status="unknown" route_status="no-route"
  now="$(epoch_now)"
  [[ -f "$STATE_DIR/network.last" ]] && last="$(<"$STATE_DIR/network.last")"
  [[ "$last" == <-> ]] || last=0

  route -n get default >/dev/null 2>&1 && route_status="route-present"

  if [[ "$route_status" == "no-route" ]]; then
    network_status="no-route"
  elif (( now - last >= NETWORK_STATE_INTERVAL_SECONDS )) || [[ ! -f "$STATE_DIR/network.status" ]]; then
    if scutil --nwi 2>/dev/null | grep -q 'Network interfaces:'; then
      network_status="route-present"
    else
      network_status="route-without-active-interface"
    fi
    print -r -- "$network_status" >| "$STATE_DIR/network.status"
    print -r -- "$now" >| "$STATE_DIR/network.last"
  else
    network_status="$(<"$STATE_DIR/network.status")"
    [[ "$network_status" == "no-route" ]] && network_status="route-present"
  fi
  print -r -- "$network_status"
}

run_https_probe() {
  local url="$1" output="$2" result curl_exit
  if [[ "$url" != https://* ]]; then
    print -r -- $'90\t000\t0\t0\t0\t0\t-' >| "$output"
    return
  fi

  result="$("$CURL_BIN" --silent --show-error --output /dev/null --location --max-redirs 2 \
    --connect-timeout "$INTERNET_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$INTERNET_TOTAL_TIMEOUT_SECONDS" \
    --user-agent 'MacLagMonitor/1.1' \
    --write-out $'%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_total}\t%{remote_ip}' \
    "$url" 2>/dev/null)"
  curl_exit=$?
  [[ -n "$result" ]] || result=$'000\t0\t0\t0\t0\t-'
  print -r -- "${curl_exit}"$'\t'"${result}" >| "$output"
}

network_events_header() {
  print -r -- $'timestamp\tevent\tprevious_state\tcurrent_state\tlast_success\toutage_started\toutage_duration_sec\tdetails'
}

ensure_network_events_header() {
  [[ -s "$NETWORK_EVENTS_FILE" ]] || network_events_header >| "$NETWORK_EVENTS_FILE"
}

record_internet_transition() {
  local current="$1" details="$2" previous="unknown" now_text now_epoch
  local last_success="unknown" outage_started="" outage_epoch=0 duration=""
  now_text="$(timestamp)"
  now_epoch="$(epoch_now)"
  INTERNET_OUTAGE_NEW=0

  [[ -f "$STATE_DIR/internet.current" ]] && previous="$(<"$STATE_DIR/internet.current")"
  [[ -f "$STATE_DIR/internet.last-success" ]] && last_success="$(<"$STATE_DIR/internet.last-success")"
  [[ -f "$STATE_DIR/internet.outage-start" ]] && outage_started="$(<"$STATE_DIR/internet.outage-start")"
  [[ -f "$STATE_DIR/internet.outage-epoch" ]] && outage_epoch="$(<"$STATE_DIR/internet.outage-epoch")"
  [[ "$outage_epoch" == <-> ]] || outage_epoch=0

  if [[ "$current" == "disabled" ]]; then
    INTERNET_LAST_SUCCESS="$last_success"
    INTERNET_OUTAGE_STARTED="$outage_started"
    return
  fi

  ensure_network_events_header
  if [[ "$current" == "online" ]]; then
    if [[ "$previous" != "online" && "$previous" != "unknown" && -n "$outage_started" ]]; then
      (( outage_epoch > 0 )) && duration=$(( now_epoch - outage_epoch ))
      print -r -- "${now_text}"$'\t'"recovered"$'\t'"${previous}"$'\t'"online"$'\t'"${last_success}"$'\t'"${outage_started}"$'\t'"${duration}"$'\t'"${details}" >> "$NETWORK_EVENTS_FILE"
      log_message "internet-recovered outage_started=${outage_started} duration_sec=${duration:-unknown}"
    elif [[ "$previous" == "unknown" ]]; then
      print -r -- "${now_text}"$'\t'"initialized"$'\t'"unknown"$'\t'"online"$'\t'"${now_text}"$'\t\t\t'"${details}" >> "$NETWORK_EVENTS_FILE"
    fi
    print -r -- "$now_text" >| "$STATE_DIR/internet.last-success"
    last_success="$now_text"
    rm -f -- "$STATE_DIR/internet.outage-start" "$STATE_DIR/internet.outage-epoch"
    outage_started=""
  elif [[ "$current" != "disabled" ]]; then
    if [[ "$previous" == "online" || "$previous" == "unknown" || -z "$outage_started" ]]; then
      outage_started="$now_text"
      print -r -- "$outage_started" >| "$STATE_DIR/internet.outage-start"
      print -r -- "$now_epoch" >| "$STATE_DIR/internet.outage-epoch"
      INTERNET_OUTAGE_NEW=1
      print -r -- "${now_text}"$'\t'"outage-start"$'\t'"${previous}"$'\t'"${current}"$'\t'"${last_success}"$'\t'"${outage_started}"$'\t0\t'"${details}" >> "$NETWORK_EVENTS_FILE"
      log_message "internet-outage-start state=${current} last_success=${last_success}"
    elif [[ "$previous" != "$current" ]]; then
      print -r -- "${now_text}"$'\t'"outage-state-change"$'\t'"${previous}"$'\t'"${current}"$'\t'"${last_success}"$'\t'"${outage_started}"$'\t\t'"${details}" >> "$NETWORK_EVENTS_FILE"
    fi
  fi

  print -r -- "$current" >| "$STATE_DIR/internet.current"
  INTERNET_LAST_SUCCESS="$last_success"
  INTERNET_OUTAGE_STARTED="$outage_started"
}

collect_internet_metrics() {
  local network_state="$1" primary_file secondary_file p_pid s_pid
  local p_exit=90 p_http=000 p_dns=0 p_connect=0 p_tls=0 p_total=0 p_ip=-
  local s_exit=90 s_http=000 s_dns=0 s_connect=0 s_tls=0 s_total=0 s_ip=-
  local p_ok=0 s_ok=0 details fastest

  INTERNET_STATE="disabled"
  DNS_STATE="not-tested"
  INTERNET_LATENCY_MS="0"
  INTERNET_PROBE_CODES="disabled"
  INTERNET_OUTAGE_NEW=0

  if (( INTERNET_CHECK_ENABLED != 1 )); then
    record_internet_transition "disabled" "checks-disabled"
    return
  fi

  if [[ "$network_state" == "no-route" ]]; then
    INTERNET_STATE="offline-no-route"
    DNS_STATE="not-tested"
    INTERNET_PROBE_CODES="route=missing"
    record_internet_transition "$INTERNET_STATE" "$INTERNET_PROBE_CODES"
    return
  fi

  primary_file="$STATE_DIR/.internet-primary.$$"
  secondary_file="$STATE_DIR/.internet-secondary.$$"
  run_https_probe "$INTERNET_CHECK_PRIMARY_URL" "$primary_file" &
  p_pid=$!
  run_https_probe "$INTERNET_CHECK_SECONDARY_URL" "$secondary_file" &
  s_pid=$!
  wait "$p_pid" 2>/dev/null || true
  wait "$s_pid" 2>/dev/null || true

  [[ -f "$primary_file" ]] && IFS=$'\t' read -r p_exit p_http p_dns p_connect p_tls p_total p_ip < "$primary_file"
  [[ -f "$secondary_file" ]] && IFS=$'\t' read -r s_exit s_http s_dns s_connect s_tls s_total s_ip < "$secondary_file"
  rm -f -- "$primary_file" "$secondary_file"
  [[ "$p_exit" == <-> ]] || p_exit=90
  [[ "$s_exit" == <-> ]] || s_exit=90
  [[ "$p_http" == <-> ]] || p_http=000
  [[ "$s_http" == <-> ]] || s_http=000
  (( p_exit == 0 && p_http > 0 )) && p_ok=1
  (( s_exit == 0 && s_http > 0 )) && s_ok=1

  details="primary=${p_exit}/${p_http},secondary=${s_exit}/${s_http}"
  INTERNET_PROBE_CODES="$details"
  if (( p_ok == 1 || s_ok == 1 )); then
    INTERNET_STATE="online"
    DNS_STATE="resolved"
    if (( p_ok == 1 && s_ok == 1 )); then
      fastest="$(awk -v a="$p_total" -v b="$s_total" 'BEGIN {print (a < b ? a : b)}')"
    elif (( p_ok == 1 )); then
      fastest="$p_total"
    else
      fastest="$s_total"
    fi
    INTERNET_LATENCY_MS="$(awk -v sec="$fastest" 'BEGIN {printf "%.0f", sec * 1000}')"
  elif (( p_exit == 6 && s_exit == 6 )); then
    INTERNET_STATE="offline-dns"
    DNS_STATE="failed"
  else
    INTERNET_STATE="offline-connect"
    if awk -v a="$p_dns" -v b="$s_dns" 'BEGIN {exit !((a+0) > 0 || (b+0) > 0)}'; then
      DNS_STATE="resolved"
    else
      DNS_STATE="unknown"
    fi
  fi
  record_internet_transition "$INTERNET_STATE" "$details"
}

collect_vm_metrics() {
  local vm pressure swap_line
  vm="$(vm_stat 2>/dev/null)"
  read -r VM_FREE_MB COMPRESSOR_MB COMPRESSED_LOGICAL_MB <<< "$(print -r -- "$vm" | awk '
    /page size of/ {gsub(/[^0-9]/,"",$8); p=$8}
    /Pages free:/ {gsub(/\./,"",$3); f=$3}
    /Pages speculative:/ {gsub(/\./,"",$3); s=$3}
    /Pages occupied by compressor:/ {gsub(/\./,"",$5); c=$5}
    /Pages stored in compressor:/ {gsub(/\./,"",$5); l=$5}
    END {
      if (!p) p=16384
      printf "%.1f %.1f %.1f\n", (f+s)*p/1048576, c*p/1048576, l*p/1048576
    }')"

  pressure="$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide memory free percentage/ {gsub(/%/,"",$2); print $2; exit}')"
  [[ "$pressure" == <-> ]] || pressure=0
  MEMORY_FREE_PERCENT="$pressure"

  swap_line="$(sysctl vm.swapusage 2>/dev/null)"
  SWAP_USED_MB="${swap_line#*used = }"
  SWAP_USED_MB="${SWAP_USED_MB%%M*}"
  [[ "$SWAP_USED_MB" == <-> || "$SWAP_USED_MB" == <->.<-> ]] || SWAP_USED_MB="0.0"
}

collect_process_metrics() {
  local ps_data
  ps_data="$("$PS_BIN" -axo pid=,ppid=,%cpu=,rss=,etime=,comm= 2>/dev/null)"

  read -r SAFARI_GROUP_KB WEBKIT_TOTAL_KB WEBKIT_MAX_KB WEBKIT_MAX_PID \
    WINDOWSERVER_CPU WINDOWSERVER_KB AUX_APP_1_KB AUX_APP_2_KB \
    SAFARI_PID SAFARI_UPTIME WEBKIT_PROCESS_COUNT REPORTCRASH_CPU \
    CORESYMBOLICATION_CPU CONTENT_FILTER_CPU CONTENT_FILTER_RUNNING WEBKIT_HOT_CPU \
    WEBKIT_HOT_PID WEBKIT_HOT_KB MEDIAANALYSISD_CPU MOBILEASSETD_CPU \
    REPLAYD_CPU <<< "$(print -r -- "$ps_data" | awk \
      -v aux1="$AUX_APP_1_PROCESS_REGEX" \
      -v aux2="$AUX_APP_2_PROCESS_REGEX" \
      -v filter_re="$CONTENT_FILTER_PROCESS_REGEX" '
    /\/Safari\.app\/|\/WebKit\.framework\/.*com\.apple\.WebKit/ {safari += $4}
    /\/WebKit\.framework\/.*com\.apple\.WebKit\.WebContent/ {
      webkit += $4; webkit_count++
      if ($4 > webkit_max) {webkit_max=$4; webkit_pid=$1}
      if ($3 > webkit_cpu_max) {webkit_cpu_max=$3; webkit_cpu_pid=$1; webkit_cpu_kb=$4}
    }
    /\/Safari\.app\/Contents\/MacOS\/Safari$/ {safari_pid=$1; safari_uptime=$5}
    /\/WindowServer$/ {window_cpu=$3; window_kb=$4}
    aux1 != "" && $0 ~ aux1 {aux1_kb += $4}
    aux2 != "" && $0 ~ aux2 {aux2_kb += $4}
    /\/ReportCrash$/ {report_cpu += $3}
    /\/coresymbolicationd$/ {symbol_cpu += $3}
    filter_re != "" && $0 ~ filter_re {filter_cpu += $3; filter_running=1}
    /\/mediaanalysisd$/ {mediaanalysis_cpu += $3}
    /\/mobileassetd$/ {mobileasset_cpu += $3}
    /\/replayd$/ {replay_cpu += $3}
    END {
      if (safari_uptime == "") safari_uptime="-"
      printf "%d %d %d %d %.1f %d %d %d %d %s %d %.1f %.1f %.1f %d %.1f %d %d %.1f %.1f %.1f\n",
        safari+0, webkit+0, webkit_max+0, webkit_pid+0,
        window_cpu+0, window_kb+0, aux1_kb+0, aux2_kb+0,
        safari_pid+0, safari_uptime, webkit_count+0,
        report_cpu+0, symbol_cpu+0, filter_cpu+0, filter_running+0,
        webkit_cpu_max+0, webkit_cpu_pid+0, webkit_cpu_kb+0,
        mediaanalysis_cpu+0, mobileasset_cpu+0, replay_cpu+0
    }')"

  SAFARI_GROUP_MB="$(mb_from_kb "$SAFARI_GROUP_KB")"
  WEBKIT_TOTAL_MB="$(mb_from_kb "$WEBKIT_TOTAL_KB")"
  WEBKIT_MAX_MB="$(mb_from_kb "$WEBKIT_MAX_KB")"
  WINDOWSERVER_MB="$(mb_from_kb "$WINDOWSERVER_KB")"
  AUX_APP_1_MB="$(mb_from_kb "$AUX_APP_1_KB")"
  AUX_APP_2_MB="$(mb_from_kb "$AUX_APP_2_KB")"
  WEBKIT_HOT_MB="$(mb_from_kb "$WEBKIT_HOT_KB")"
}

determine_trigger_flags() {
  local -a context_flags trigger_flags
  local load_high=0
  context_flags=()
  trigger_flags=()

  # Context flags preserve the sensitive historical signals in summary.tsv.
  (( $(integer_value "$MEMORY_FREE_PERCENT") <= MEMORY_FREE_PERCENT_THRESHOLD )) && context_flags+=("memory-pressure")
  (( $(integer_value "$COMPRESSOR_MB") >= COMPRESSOR_MB_THRESHOLD )) && context_flags+=("compressor-high")
  (( $(integer_value "$SAFARI_GROUP_MB") >= SAFARI_GROUP_MB_THRESHOLD )) && context_flags+=("safari-high")
  (( $(integer_value "$WEBKIT_MAX_MB") >= WEBKIT_PROCESS_MB_THRESHOLD )) && context_flags+=("webkit-process-high")
  (( $(integer_value "$WINDOWSERVER_CPU") >= WINDOWSERVER_CPU_THRESHOLD )) && context_flags+=("windowserver-high")
  (( $(integer_value "$WEBKIT_HOT_CPU") >= WEBKIT_CPU_SAMPLE_THRESHOLD )) && context_flags+=("webkit-cpu-high")

  # Incident thresholds are intentionally much stricter so routine heavy use is
  # recorded as context without automatically starting a four-minute capture.
  (( $(integer_value "$MEMORY_FREE_PERCENT") <= INCIDENT_MEMORY_FREE_PERCENT_THRESHOLD )) && trigger_flags+=("memory-pressure")
  (( $(integer_value "$COMPRESSOR_MB") >= INCIDENT_COMPRESSOR_MB_THRESHOLD )) && trigger_flags+=("compressor-high")
  (( $(integer_value "$SAFARI_GROUP_MB") >= INCIDENT_SAFARI_GROUP_MB_THRESHOLD )) && trigger_flags+=("safari-high")
  (( $(integer_value "$WEBKIT_MAX_MB") >= INCIDENT_WEBKIT_PROCESS_MB_THRESHOLD )) && trigger_flags+=("webkit-process-high")
  (( $(integer_value "$WINDOWSERVER_CPU") >= INCIDENT_WINDOWSERVER_CPU_THRESHOLD )) && trigger_flags+=("windowserver-high")
  (( $(integer_value "$WEBKIT_HOT_CPU") >= INCIDENT_WEBKIT_CPU_THRESHOLD )) && trigger_flags+=("webkit-cpu-high")

  if (( $(integer_value "$REPORTCRASH_CPU") >= REPORTCRASH_CPU_THRESHOLD )); then
    context_flags+=("crashreporter-high")
    trigger_flags+=("crashreporter-high")
  fi
  if (( $(integer_value "$CORESYMBOLICATION_CPU") >= CORESYMBOLICATION_CPU_THRESHOLD )); then
    context_flags+=("coresymbolication-high")
    trigger_flags+=("coresymbolication-high")
  fi
  if (( $(integer_value "$MEDIAANALYSISD_CPU") >= MEDIAANALYSISD_CPU_THRESHOLD )); then
    context_flags+=("mediaanalysisd-high")
    trigger_flags+=("mediaanalysisd-high")
  fi
  if (( $(integer_value "$MOBILEASSETD_CPU") >= MOBILEASSETD_CPU_THRESHOLD )); then
    context_flags+=("mobileassetd-high")
    trigger_flags+=("mobileassetd-high")
  fi
  if (( $(integer_value "$REPLAYD_CPU") >= REPLAYD_CPU_THRESHOLD )); then
    context_flags+=("replayd-high")
    trigger_flags+=("replayd-high")
  fi
  (( $(integer_value "${LOAD_1M:-0}") >= LOGICAL_CPU_COUNT * SYSTEM_LOAD_PER_LOGICAL_CPU_THRESHOLD )) && load_high=1
  if (( load_high == 1 )); then
    context_flags+=("system-load-high")
    trigger_flags+=("system-load-high")
  fi
  if (( INTERNET_OUTAGE_NEW == 1 )); then
    context_flags+=("internet-down")
    trigger_flags+=("internet-down")
  fi
  if (( FORCE_TRIGGER == 1 )); then
    context_flags+=("manual-test")
    trigger_flags+=("manual-test")
    FORCE_TRIGGER=0
  fi
  CONTEXT_FLAGS="${(j:,:)context_flags}"
  TRIGGER_FLAGS="${(j:,:)trigger_flags}"
}

summary_header() {
  print -r -- $'timestamp\tpower\tinterval_sec\tmemory_free_pct\tvm_free_mb\tcompressor_mb\tcompressed_logical_mb\tswap_used_mb\tload_1m\tsafari_group_mb\twebkit_total_mb\twebkit_max_mb\twebkit_max_pid\twindowserver_cpu_pct\twindowserver_mb\taux_app_1_mb\taux_app_2_mb\tnetwork_state\tinternet_state\tdns_state\tinternet_latency_ms\tinternet_probe_codes\tinternet_last_success\toutage_started\tsafari_pid\tsafari_uptime\twebkit_process_count\treportcrash_cpu_pct\tcoresymbolication_cpu_pct\tcontent_filter_cpu_pct\twebkit_hot_cpu_pct\twebkit_hot_pid\twebkit_hot_mb\tmediaanalysisd_cpu_pct\tmobileassetd_cpu_pct\treplayd_cpu_pct\tflags'
}

ensure_summary_header() {
  local expected first legacy
  expected="$(summary_header)"
  if [[ -s "$SUMMARY_FILE" ]]; then
    first="$(head -n 1 "$SUMMARY_FILE")"
    if [[ "$first" != "$expected" ]]; then
      legacy="$DATA_DIR/summary-legacy-$(date '+%Y%m%d-%H%M%S').tsv"
      mv -f -- "$SUMMARY_FILE" "$legacy"
      (( $(stat -f '%z' "$legacy" 2>/dev/null || print 0) > 10485760 )) && trim_file_to_bytes "$legacy" 10485760
      log_message "summary-schema-upgrade legacy=${legacy:t}"
    fi
  fi
  if [[ ! -s "$SUMMARY_FILE" ]]; then
    print -r -- "$expected" >| "$SUMMARY_FILE"
  fi
}

collect_and_write_snapshot() {
  local interval="$1" destination="${2:-}" supplied_power="${3:-}"
  local power load1 network line started finished elapsed tab=$'\t'
  started="$(epoch_now)"
  if [[ -n "$supplied_power" ]]; then
    power="$supplied_power"
  else
    power="$(current_power_mode)"
  fi
  collect_vm_metrics
  collect_process_metrics
  network="$(update_network_state_if_due)"
  collect_internet_metrics "$network"
  load1="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
  [[ -n "$load1" ]] || load1="0"
  LOAD_1M="$load1"
  determine_trigger_flags
  ensure_summary_header

  finished="$(epoch_now)"
  elapsed=$(( finished - started ))
  if (( elapsed >= SAMPLE_STALL_TRIGGER_SECONDS )); then
    [[ -n "$CONTEXT_FLAGS" ]] && CONTEXT_FLAGS+=","
    CONTEXT_FLAGS+="monitor-sample-stall"
    [[ -n "$TRIGGER_FLAGS" ]] && TRIGGER_FLAGS+=","
    TRIGGER_FLAGS+="monitor-sample-stall"
  fi
  line="$(timestamp)${tab}${power}${tab}${interval}${tab}${MEMORY_FREE_PERCENT}${tab}${VM_FREE_MB}${tab}${COMPRESSOR_MB}${tab}${COMPRESSED_LOGICAL_MB}${tab}${SWAP_USED_MB}${tab}${load1}${tab}${SAFARI_GROUP_MB}${tab}${WEBKIT_TOTAL_MB}${tab}${WEBKIT_MAX_MB}${tab}${WEBKIT_MAX_PID}${tab}${WINDOWSERVER_CPU}${tab}${WINDOWSERVER_MB}${tab}${AUX_APP_1_MB}${tab}${AUX_APP_2_MB}${tab}${network}${tab}${INTERNET_STATE}${tab}${DNS_STATE}${tab}${INTERNET_LATENCY_MS}${tab}${INTERNET_PROBE_CODES}${tab}${INTERNET_LAST_SUCCESS}${tab}${INTERNET_OUTAGE_STARTED}${tab}${SAFARI_PID}${tab}${SAFARI_UPTIME}${tab}${WEBKIT_PROCESS_COUNT}${tab}${REPORTCRASH_CPU}${tab}${CORESYMBOLICATION_CPU}${tab}${CONTENT_FILTER_CPU}${tab}${WEBKIT_HOT_CPU}${tab}${WEBKIT_HOT_PID}${tab}${WEBKIT_HOT_MB}${tab}${MEDIAANALYSISD_CPU}${tab}${MOBILEASSETD_CPU}${tab}${REPLAYD_CPU}${tab}${CONTEXT_FLAGS}"
  print -r -- "$line" >> "$SUMMARY_FILE"
  [[ -n "$destination" ]] && print -r -- "$line" >> "$destination"

  if (( elapsed > SELF_MAX_SAMPLE_SECONDS )); then
    log_message "sample-slow elapsed=${elapsed}s"
  fi
}

capture_safari_domains() {
  local output="$1"
  if (( CAPTURE_SAFARI_DOMAINS != 1 )); then
    print -r -- "disabled" >| "$output"
    return
  fi

  osascript -l JavaScript 2>/dev/null <<'JXA' | awk -F '\t' '
    function domain(url, x) {
      x=url
      sub(/^[A-Za-z]+:\/\//,"",x)
      sub(/[\/?#].*$/,"",x)
      return tolower(x)
    }
    NF >= 4 {
      d=domain($4)
      if (d != "") printf "window=%s\ttab=%s\tactive=%s\tdomain=%s\n", $1, $2, $3, d
    }
  ' >| "$output"
const safari = Application('Safari');
const lines = [];
try {
  safari.windows().forEach((w, wi) => {
    let activeURL = '';
    try { activeURL = w.currentTab().url() || ''; } catch (e) {}
    w.tabs().forEach((t, ti) => {
      let url = '';
      try { url = t.url() || ''; } catch (e) {}
      if (url) lines.push(`${wi + 1}\t${ti + 1}\t${url === activeURL ? 1 : 0}\t${url}`);
    });
  });
} catch (e) {}
lines.join('\n');
JXA
  [[ -s "$output" ]] || print -r -- "no-readable-safari-tabs" >| "$output"
}

generate_cross_incident_domain_correlation() {
  local incident_dir="$1" reason="$2" output="$incident_dir/domain-correlation.txt"
  local dir file line domain tab=$'\t' count hot active ratio relevance current_relevant=0
  local scanned=0 with_domains=0 repeated=0 top_count=0 top_hot=0 top_active=0
  local top_domain="" strength="none"
  local -a recent_dirs domain_files hot_files candidates sorted_candidates
  typeset -A counts hot_counts active_counts seen hot_seen active_seen

  DOMAIN_CORRELATION_FOUND=0
  DOMAIN_CORRELATION_TOP_DOMAIN=""
  DOMAIN_CORRELATION_TOP_COUNT=0
  DOMAIN_CORRELATION_TOP_HOT_COUNT=0
  DOMAIN_CORRELATION_TOP_ACTIVE_COUNT=0
  DOMAIN_CORRELATION_INCIDENTS_WITH_DOMAINS=0
  DOMAIN_CORRELATION_STRENGTH="none"

  if (( CAPTURE_SAFARI_DOMAINS != 1 )); then
    print -r -- "disabled-by-privacy-setting" >| "$output"
    return
  fi

  if [[ "$reason" == *safari-high* || "$reason" == *webkit-process-high* || "$reason" == *webkit-cpu-high* ]] || (( MACOS_WEBKIT_RESOURCE_FOUND == 1 )); then
    current_relevant=1
  else
    hot_files=("$incident_dir"/hot-webkit-*-safari-domains.txt(N.))
    (( ${#hot_files} > 0 )) && current_relevant=1
  fi
  if (( current_relevant == 0 )); then
    print -r -- "not-applicable-no-webkit-evidence" >| "$output"
    return
  fi

  recent_dirs=("${(@f)$(find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r | head -n "$DOMAIN_CORRELATION_MAX_INCIDENTS")}")
  for dir in "${recent_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    relevance=0
    if [[ "$dir" == "$incident_dir" ]]; then
      relevance=1
    elif [[ -f "$dir/metadata.txt" ]] && /usr/bin/grep -Eq '^reason=.*(safari-high|webkit-process-high|webkit-cpu-high)' "$dir/metadata.txt" 2>/dev/null; then
      relevance=1
    elif [[ -f "$dir/diagnosis.txt" ]] && /usr/bin/grep -Eq '^(classification|primary_suspect)=.*webkit' "$dir/diagnosis.txt" 2>/dev/null; then
      relevance=1
    else
      hot_files=("$dir"/hot-webkit-*-safari-domains.txt(N.))
      (( ${#hot_files} > 0 )) && relevance=1
    fi
    (( relevance == 1 )) || continue
    (( scanned++ ))

    seen=()
    hot_seen=()
    active_seen=()
    domain_files=("$dir"/*-safari-domains.txt(N.))
    for file in "${domain_files[@]}"; do
      [[ -f "$file" ]] || continue
      while IFS= read -r line; do
        [[ "$line" == *"domain="* ]] || continue
        domain="${line##*domain=}"
        domain="${domain%%$'\t'*}"
        [[ -n "$domain" ]] || continue
        seen[$domain]=1
        [[ "${file:t}" == hot-webkit-* ]] && hot_seen[$domain]=1
        if [[ "$line" == *$'\tactive=1\t'* || "$line" == active=1$'\t'* ]]; then
          active_seen[$domain]=1
        fi
      done < "$file"
    done

    if (( ${#seen} > 0 )); then
      (( with_domains++ ))
      for domain in ${(k)seen}; do
        counts[$domain]=$(( ${counts[$domain]:-0} + 1 ))
      done
      for domain in ${(k)hot_seen}; do
        hot_counts[$domain]=$(( ${hot_counts[$domain]:-0} + 1 ))
      done
      for domain in ${(k)active_seen}; do
        active_counts[$domain]=$(( ${active_counts[$domain]:-0} + 1 ))
      done
    fi
  done

  for domain in ${(k)counts}; do
    count=${counts[$domain]:-0}
    hot=${hot_counts[$domain]:-0}
    active=${active_counts[$domain]:-0}
    (( count >= DOMAIN_CORRELATION_MIN_REPEAT )) || continue
    (( repeated++ ))
    candidates+=("${count}${tab}${hot}${tab}${active}${tab}${domain}")
    if (( count > top_count || (count == top_count && hot > top_hot) || (count == top_count && hot == top_hot && active > top_active) )); then
      top_count=$count
      top_hot=$hot
      top_active=$active
      top_domain="$domain"
    fi
  done

  if (( top_count >= DOMAIN_CORRELATION_MIN_REPEAT && with_domains > 0 )); then
    ratio=$(( top_count * 100 / with_domains ))
    if (( top_active >= 2 && ratio >= 50 )); then
      strength="medium"
    elif (( top_hot >= 2 && ratio >= 50 )); then
      strength="low-medium"
    else
      strength="low"
    fi
    DOMAIN_CORRELATION_FOUND=1
    DOMAIN_CORRELATION_TOP_DOMAIN="$top_domain"
    DOMAIN_CORRELATION_TOP_COUNT=$top_count
    DOMAIN_CORRELATION_TOP_HOT_COUNT=$top_hot
    DOMAIN_CORRELATION_TOP_ACTIVE_COUNT=$top_active
    DOMAIN_CORRELATION_INCIDENTS_WITH_DOMAINS=$with_domains
    DOMAIN_CORRELATION_STRENGTH="$strength"
  fi

  {
    print -r -- "MacLagMonitor cross-incident Safari domain correlation"
    print -r -- "generated=$(timestamp)"
    print -r -- "incidents_scanned=$scanned"
    print -r -- "incidents_with_readable_domains=$with_domains"
    print -r -- "minimum_repeat=$DOMAIN_CORRELATION_MIN_REPEAT"
    print -r -- "repeated_domain_count=$repeated"
    if (( DOMAIN_CORRELATION_FOUND == 1 )); then
      ratio=$(( DOMAIN_CORRELATION_TOP_COUNT * 100 / DOMAIN_CORRELATION_INCIDENTS_WITH_DOMAINS ))
      print -r -- "top_candidate_domain=$DOMAIN_CORRELATION_TOP_DOMAIN"
      print -r -- "top_candidate_incident_count=$DOMAIN_CORRELATION_TOP_COUNT"
      print -r -- "top_candidate_incident_ratio_pct=$ratio"
      print -r -- "top_candidate_hot_capture_count=$DOMAIN_CORRELATION_TOP_HOT_COUNT"
      print -r -- "top_candidate_active_tab_count=$DOMAIN_CORRELATION_TOP_ACTIVE_COUNT"
      print -r -- "top_candidate_association_strength=$DOMAIN_CORRELATION_STRENGTH"
    else
      print -r -- "top_candidate_domain=none"
    fi
    print -r -- ""
    print -r -- "top_repeated_candidates:"
    if (( ${#candidates} == 0 )); then
      print -r -- "none"
    else
      sorted_candidates=("${(@f)$(printf '%s\n' "${candidates[@]}" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4 | head -n "$DOMAIN_CORRELATION_TOP_RESULTS")}")
      for line in "${sorted_candidates[@]}"; do
        IFS=$'\t' read -r count hot active domain <<< "$line"
        ratio=$(( with_domains > 0 ? count * 100 / with_domains : 0 ))
        print -r -- "domain=$domain incidents=${count}/${with_domains} ratio_pct=$ratio hot_captures=$hot active_tab_incidents=$active"
      done
    fi
    print -r -- ""
    print -r -- "limits=반복 등장은 연관 후보일 뿐 원인 증명이 아님. 오래 열어 둔 공통 탭도 반복될 수 있으므로 macOS resource report·PID·종료 후 회복 증거와 함께 해석해야 함"
  } >| "$output"
}

trim_file_to_bytes() {
  local file="$1" bytes="$2" temp
  [[ -f "$file" ]] || return
  temp="${file}.trim.$$"
  tail -c "$bytes" "$file" >| "$temp" 2>/dev/null || return
  mv -f -- "$temp" "$file"
}

trim_summary_to_bytes() {
  local bytes="$1" temp body
  [[ -f "$SUMMARY_FILE" ]] || return
  temp="${SUMMARY_FILE}.trim.$$"
  body="${SUMMARY_FILE}.body.$$"
  tail -c "$bytes" "$SUMMARY_FILE" >| "$body" 2>/dev/null || return
  # tail -c can begin in the middle of a TSV row; discard that partial row.
  sed '1d' "$body" >| "$temp"
  {
    summary_header
    cat "$temp"
  } >| "$body"
  mv -f -- "$body" "$SUMMARY_FILE"
  rm -f -- "$temp"
}

trim_network_events_to_bytes() {
  local bytes="$1" temp body
  [[ -f "$NETWORK_EVENTS_FILE" ]] || return
  temp="${NETWORK_EVENTS_FILE}.trim.$$"
  body="${NETWORK_EVENTS_FILE}.body.$$"
  tail -c "$bytes" "$NETWORK_EVENTS_FILE" >| "$body" 2>/dev/null || return
  sed '1d' "$body" >| "$temp"
  {
    network_events_header
    cat "$temp"
  } >| "$body"
  mv -f -- "$body" "$NETWORK_EVENTS_FILE"
  rm -f -- "$temp"
}

safe_delete_directory() {
  local target="$1"
  [[ -n "$target" && "$target" == "$INCIDENTS_DIR"/* && -d "$target" ]] || return 1
  find "$target" -depth -delete 2>/dev/null
}

directory_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1+0}'
}

rotate_storage() {
  local summary_limit_bytes total_limit_kb incidents_limit_kb single_limit_bytes
  local dir file total oldest incident_count incidents_kb largest
  summary_limit_bytes=$(( SUMMARY_SIZE_LIMIT_MB * 1024 * 1024 ))
  single_limit_bytes=$(( SINGLE_INCIDENT_SIZE_LIMIT_MB * 1024 * 1024 ))
  total_limit_kb=$(( TOTAL_SIZE_LIMIT_MB * 1024 ))
  incidents_limit_kb=$(( INCIDENTS_SIZE_LIMIT_MB * 1024 ))

  if [[ -f "$SUMMARY_FILE" ]] && (( $(stat -f '%z' "$SUMMARY_FILE" 2>/dev/null || print 0) > summary_limit_bytes )); then
    trim_summary_to_bytes $(( summary_limit_bytes * 3 / 4 ))
  fi
  if [[ -f "$SERVICE_LOG" ]] && (( $(stat -f '%z' "$SERVICE_LOG" 2>/dev/null || print 0) > 10485760 )); then
    trim_file_to_bytes "$SERVICE_LOG" 5242880
  fi
  for file in "$LOG_DIR/launchd-stdout.log" "$LOG_DIR/launchd-stderr.log"; do
    if [[ -f "$file" ]] && (( $(stat -f '%z' "$file" 2>/dev/null || print 0) > LAUNCHD_LOG_SIZE_LIMIT_MB * 1024 * 1024 )); then
      trim_file_to_bytes "$file" $(( LAUNCHD_LOG_SIZE_LIMIT_MB * 512 * 1024 ))
    fi
  done
  if [[ -f "$NETWORK_EVENTS_FILE" ]] && (( $(stat -f '%z' "$NETWORK_EVENTS_FILE" 2>/dev/null || print 0) > 5242880 )); then
    trim_network_events_to_bytes 3145728
  fi

  while IFS= read -r dir; do
    [[ -n "$dir" ]] && safe_delete_directory "$dir"
  done < <(find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -print 2>/dev/null)

  for dir in "$INCIDENTS_DIR"/*(N/); do
    if (( $(directory_kb "$dir") * 1024 > single_limit_bytes )); then
      for file in "$dir"/*(N.); do
        (( $(stat -f '%z' "$file" 2>/dev/null || print 0) > 1048576 )) && trim_file_to_bytes "$file" 1048576
      done
      # A future diagnostic may add more files. Remove the largest non-core files
      # until the hard per-incident limit is met.
      while (( $(directory_kb "$dir") * 1024 > single_limit_bytes )); do
        largest="$(find "$dir" -maxdepth 1 -type f ! -name 'metadata.txt' ! -name 'timeline.tsv' -exec stat -f '%z %N' {} + 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)"
        [[ -n "$largest" && -f "$largest" ]] || break
        rm -f -- "$largest"
      done
    fi
  done

  incident_count="$(find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  while (( incident_count > MAX_INCIDENT_COUNT )); do
    oldest="$(find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | head -n 1)"
    [[ -n "$oldest" ]] || break
    safe_delete_directory "$oldest"
    (( incident_count-- ))
  done

  incidents_kb="$(directory_kb "$INCIDENTS_DIR")"
  while (( incidents_kb > incidents_limit_kb )); do
    oldest="$(find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | head -n 1)"
    [[ -n "$oldest" ]] || break
    safe_delete_directory "$oldest"
    incidents_kb="$(directory_kb "$INCIDENTS_DIR")"
  done

  total="$(directory_kb "$INSTALL_ROOT")"
  while (( total > total_limit_kb )); do
    oldest="$(find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | head -n 1)"
    if [[ -n "$oldest" ]]; then
      safe_delete_directory "$oldest"
    else
      trim_summary_to_bytes 10485760
      trim_file_to_bytes "$SERVICE_LOG" 2097152
      break
    fi
    total="$(directory_kb "$INSTALL_ROOT")"
  done
}

maybe_rotate_storage() {
  local force="${1:-0}" now last=0
  now="$(epoch_now)"
  [[ -f "$STATE_DIR/storage-maintenance.last" ]] && last="$(<"$STATE_DIR/storage-maintenance.last")"
  [[ "$last" == <-> ]] || last=0

  if (( force != 1 && STORAGE_MAINTENANCE_INTERVAL_SECONDS > 0 && now - last < STORAGE_MAINTENANCE_INTERVAL_SECONDS )); then
    return
  fi

  rotate_storage
  print -r -- "$now" >| "$STATE_DIR/storage-maintenance.last"
}

capture_detailed_state() {
  local incident_dir="$1" phase="$2" detail
  detail="$incident_dir/${phase}-detail.txt"
  {
    print -r -- "timestamp: $(timestamp)"
    print -r -- "phase: $phase"
    print -r -- "uptime: $(uptime 2>/dev/null)"
    print -r -- "macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
    print -r -- "--- memory_pressure ---"
    memory_pressure 2>&1
    print -r -- "--- vm_stat ---"
    vm_stat 2>&1
    print -r -- "--- swap ---"
    sysctl vm.swapusage 2>&1
    print -r -- "--- top memory processes ---"
    "$PS_BIN" -axo pid,ppid,%cpu,%mem,rss,state,etime,comm 2>&1 | sort -k5 -nr | head -n 80
    print -r -- "--- top CPU processes ---"
    "$PS_BIN" -axo pid,ppid,%cpu,%mem,rss,state,etime,comm 2>&1 | sort -k3 -nr | head -n 80
    print -r -- "--- power ---"
    pmset -g batt 2>&1
    pmset -g therm 2>&1
    print -r -- "--- network path ---"
    scutil --nwi 2>&1
    route -n get default 2>&1
    print -r -- "--- internet monitor state ---"
    print -r -- "internet_state: ${INTERNET_STATE:-unknown}"
    print -r -- "dns_state: ${DNS_STATE:-unknown}"
    print -r -- "internet_latency_ms: ${INTERNET_LATENCY_MS:-unknown}"
    print -r -- "internet_probe_codes: ${INTERNET_PROBE_CODES:-unknown}"
    print -r -- "internet_last_success: ${INTERNET_LAST_SUCCESS:-unknown}"
    print -r -- "outage_started: ${INTERNET_OUTAGE_STARTED:-unknown}"
    print -r -- "--- disk ---"
    df -h /System/Volumes/Data 2>&1
    print -r -- "--- nfcd launch state ---"
    launchctl print system/com.apple.nfcd 2>&1 | head -n 80
  } >| "$detail"

  if (( SAFARI_PID > 0 )) && \
    (( $(integer_value "$SAFARI_GROUP_MB") >= INCIDENT_SAFARI_GROUP_MB_THRESHOLD || \
       $(integer_value "$WEBKIT_MAX_MB") >= INCIDENT_WEBKIT_PROCESS_MB_THRESHOLD || \
       $(integer_value "$WEBKIT_HOT_CPU") >= WEBKIT_CPU_SAMPLE_THRESHOLD )); then
    capture_safari_domains "$incident_dir/${phase}-safari-domains.txt"
  else
    print -r -- "not-captured-no-safari-webkit-symptom" >| "$incident_dir/${phase}-safari-domains.txt"
  fi
}

capture_hot_webkit_sample() {
  local incident_dir="$1" count="$2" output tabs
  (( PROCESS_SAMPLE_SECONDS > 0 )) || return 1
  (( WEBKIT_HOT_PID > 0 )) || return 1
  (( $(integer_value "$WEBKIT_HOT_CPU") >= WEBKIT_CPU_SAMPLE_THRESHOLD )) || return 1
  kill -0 "$WEBKIT_HOT_PID" 2>/dev/null || return 1

  output="$incident_dir/hot-webkit-$(printf '%02d' "$count")-pid-${WEBKIT_HOT_PID}.sample.txt"
  tabs="$incident_dir/hot-webkit-$(printf '%02d' "$count")-safari-domains.txt"
  "$SAMPLE_BIN" "$WEBKIT_HOT_PID" "$PROCESS_SAMPLE_SECONDS" -file "$output" >/dev/null 2>&1 || true
  if [[ -f "$output" ]] && (( $(stat -f '%z' "$output" 2>/dev/null || print 0) > PROCESS_SAMPLE_MAX_KB * 1024 )); then
    trim_file_to_bytes "$output" $(( PROCESS_SAMPLE_MAX_KB * 1024 ))
  fi
  capture_safari_domains "$tabs"
  {
    print -r -- "captured=$(timestamp)"
    print -r -- "sample_number=$count"
    print -r -- "webkit_pid=$WEBKIT_HOT_PID"
    print -r -- "webkit_cpu_pct=$WEBKIT_HOT_CPU"
    print -r -- "webkit_rss_mb=$WEBKIT_HOT_MB"
  } >> "$incident_dir/webkit-hot-samples.txt"
  return 0
}

capture_recent_system_logs() {
  local incident_dir="$1" incident_start_epoch="$2" incident_end_epoch="$3"
  local output temp status_file start_text end_text started now elapsed size max_temp max_output reason="completed"
  output="$incident_dir/recent-system-events.log"
  temp="$incident_dir/.system-log.tmp"
  status_file="$incident_dir/system-log-capture-status.txt"
  start_text="$(date -r $(( incident_start_epoch - SYSTEM_LOG_LOOKBACK_MINUTES * 60 )) '+%Y-%m-%d %H:%M:%S')"
  end_text="$(date -r "$incident_end_epoch" '+%Y-%m-%d %H:%M:%S')"
  max_temp=$(( SYSTEM_LOG_TEMP_MAX_MB * 1024 * 1024 ))
  max_output=$(( SYSTEM_LOG_OUTPUT_MAX_MB * 1024 * 1024 ))
  started="$(epoch_now)"

  (
    ulimit -f $(( max_temp / 512 )) 2>/dev/null || true
    exec "$LOG_BIN" show --start "$start_text" --end "$end_text" --style compact \
      --predicate '(eventMessage CONTAINS[c] "memory pressure" OR eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "network is unreachable" OR eventMessage CONTAINS[c] "invalid message" OR eventMessage CONTAINS[c] "EXC_GUARD" OR (process == "mediaanalysisd" AND (eventMessage CONTAINS[c] "MADService" OR eventMessage CONTAINS[c] "photos.textunderstanding" OR eventMessage CONTAINS[c] "background processing")) OR (process == "mobileassetd" AND (eventMessage CONTAINS[c] "requested purge-all" OR eventMessage CONTAINS[c] "Found no downloads" OR eventMessage CONTAINS[c] "download" OR eventMessage CONTAINS[c] "stale entry")) OR process == "replayd" OR process == "ReportCrash" OR process == "coresymbolicationd")'
  ) >| "$temp" 2>/dev/null &
  LOG_CAPTURE_PID=$!

  while kill -0 "$LOG_CAPTURE_PID" 2>/dev/null; do
    now="$(epoch_now)"
    elapsed=$(( now - started ))
    size="$(stat -f '%z' "$temp" 2>/dev/null || print 0)"
    if (( elapsed >= SYSTEM_LOG_CAPTURE_TIMEOUT_SECONDS )); then
      reason="timeout"
      kill -TERM "$LOG_CAPTURE_PID" 2>/dev/null || true
      sleep 1
      kill -KILL "$LOG_CAPTURE_PID" 2>/dev/null || true
      break
    fi
    if (( size >= max_temp )); then
      reason="size-limit"
      kill -TERM "$LOG_CAPTURE_PID" 2>/dev/null || true
      sleep 1
      kill -KILL "$LOG_CAPTURE_PID" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  wait "$LOG_CAPTURE_PID" 2>/dev/null || true
  LOG_CAPTURE_PID=0
  elapsed=$(( $(epoch_now) - started ))
  size="$(stat -f '%z' "$temp" 2>/dev/null || print 0)"
  if [[ "$reason" == "completed" ]] && (( size >= max_temp )); then
    reason="size-limit"
  fi

  if (( size > max_output )); then
    { print -r -- "[earlier log lines removed by ${SYSTEM_LOG_OUTPUT_MAX_MB}MB output cap]"; tail -c "$max_output" "$temp" | sed '1d'; } >| "$output"
  else
    cp -f -- "$temp" "$output" 2>/dev/null || : >| "$output"
  fi
  rm -f -- "$temp"
  {
    print -r -- "start=$start_text"
    print -r -- "end=$end_text"
    print -r -- "elapsed_seconds=$elapsed"
    print -r -- "completion=$reason"
    print -r -- "temporary_bytes=$size"
    print -r -- "output_bytes=$(stat -f '%z' "$output" 2>/dev/null || print 0)"
    print -r -- "timeout_seconds=$SYSTEM_LOG_CAPTURE_TIMEOUT_SECONDS"
    print -r -- "temporary_limit_mb=$SYSTEM_LOG_TEMP_MAX_MB"
    print -r -- "output_limit_mb=$SYSTEM_LOG_OUTPUT_MAX_MB"
  } >| "$status_file"
  log_message "system-log-capture completion=$reason elapsed=${elapsed}s temp_bytes=$size"
}

capture_recent_system_logs_if_relevant() {
  local incident_dir="$1" incident_start_epoch="$2" incident_end_epoch="$3" trigger_reason="$4"
  local status_file="$incident_dir/system-log-capture-status.txt"
  local output="$incident_dir/recent-system-events.log"

  case ",$trigger_reason," in
    *",manual-test,"*|*",internet-down,"*|*",monitor-sample-stall,"*|*",memory-pressure,"*|*",compressor-high,"*|*",crashreporter-high,"*|*",coresymbolication-high,"*|*",webkit-cpu-high,"*|*",mediaanalysisd-high,"*|*",mobileassetd-high,"*|*",replayd-high,"*|*",system-load-high,"*)
      capture_recent_system_logs "$incident_dir" "$incident_start_epoch" "$incident_end_epoch"
      ;;
    *)
      : >| "$output"
      {
        print -r -- "completion=skipped"
        print -r -- "reason=no-relevant-system-log-predicate"
        print -r -- "trigger_reason=$trigger_reason"
      } >| "$status_file"
      log_message "system-log-capture completion=skipped trigger_reason=$trigger_reason"
      ;;
  esac
}

capture_safari_fault_reports() {
  local incident_dir="$1" output temp max_bytes report count=0
  local -a reports
  output="$incident_dir/safari-fault-summary.txt"
  temp="$incident_dir/.safari-fault-summary.tmp"
  SAFARI_FAULT_FOUND=0

  if (( SAFARI_DIAGNOSTICS_ENABLED != 1 )); then
    print -r -- "disabled" >| "$output"
    return
  fi

  max_bytes=$(( SAFARI_FAULT_EXTRACT_MAX_KB * 1024 ))
  reports=("${(@f)$(find "$DIAGNOSTIC_REPORTS_DIR" "$SYSTEM_DIAGNOSTIC_REPORTS_DIR" \
    -maxdepth 1 -type f \
    \( -name 'ExcUserFault_Safari*.ips' -o -name '*WebKit*.ips' -o -name 'Safari*.ips' \
       -o -name 'coresymbolicationd*.diag' -o -name 'ReportCrash*.diag' \) \
    -mmin "-${SYSTEM_LOG_LOOKBACK_MINUTES}" -print 2>/dev/null | sort -r | head -n "$SAFARI_FAULT_MAX_REPORTS")}" )

  : >| "$temp"
  for report in "${reports[@]}"; do
    [[ -f "$report" ]] || continue
    (( count++ ))
    print -r -- "=== report ${count} ===" >> "$temp"
    print -r -- "path: $report" >> "$temp"
    stat -f 'modified: %Sm%nsize_bytes: %z' -t '%Y-%m-%dT%H:%M:%S%z' "$report" >> "$temp" 2>/dev/null || true
    print -r -- "metadata:" >> "$temp"
    sed -n '1p' "$report" 2>/dev/null | cut -c 1-4096 >> "$temp"
    print -r -- "key_fields:" >> "$temp"
    /usr/bin/grep -E '"(captureTime|procLaunch|pid|procName|exception|termination|isSimulated|bug_type)"|^(Date/Time|End time|Event|Writes|Writes limit|Writes duration):' "$report" 2>/dev/null \
      | head -n 40 | cut -c 1-4096 >> "$temp" || true
    print -r -- "key_symbols:" >> "$temp"
    /usr/bin/grep -o 'symbol":"[^"]*' "$report" 2>/dev/null | head -n 16 | cut -c 1-1024 >> "$temp" || true
    print -r -- "" >> "$temp"
  done

  if (( count == 0 )); then
    print -r -- "no-recent-safari-or-webkit-report" >| "$output"
  else
    head -c "$max_bytes" "$temp" >| "$output"
    if /usr/bin/grep -Eq 'EXC_GUARD|namespace.*WEBKIT|didReceiveInvalidMessage|invalid message' "$output" 2>/dev/null; then
      SAFARI_FAULT_FOUND=1
    fi
  fi
  rm -f -- "$temp"
}

capture_macos_resource_reports() {
  local incident_dir="$1" start_epoch="$2" end_epoch="$3"
  local output="$incident_dir/macos-resource-reports.txt" line report mtime count=0
  local command pid cpu footprint stack_hint
  local -a ranked

  MACOS_RESOURCE_FOUND=0
  MACOS_WEBKIT_RESOURCE_FOUND=0
  MACOS_RESOURCE_REPORT_PATH=""
  MACOS_RESOURCE_COMMAND=""
  MACOS_RESOURCE_PID=""
  MACOS_RESOURCE_CPU=""
  MACOS_RESOURCE_FOOTPRINT=""
  MACOS_RESOURCE_STACK_HINT=""
  : >| "$output"

  ranked=("${(@f)$(find "$DIAGNOSTIC_REPORTS_DIR" "$SYSTEM_DIAGNOSTIC_REPORTS_DIR" -maxdepth 1 -type f -name '*.cpu_resource.diag' -print0 2>/dev/null \
    | xargs -0 stat -f $'%m\t%N' 2>/dev/null | sort -rn 2>/dev/null)}")

  for line in "${ranked[@]}"; do
    mtime="${line%%$'\t'*}"
    report="${line#*$'\t'}"
    [[ "$mtime" == <-> && -f "$report" ]] || continue
    (( mtime >= start_epoch - SYSTEM_LOG_LOOKBACK_MINUTES * 60 )) || continue
    (( mtime <= end_epoch + 60 )) || continue
    (( count++ ))
    MACOS_RESOURCE_FOUND=1

    command="$(/usr/bin/grep -m1 '^Command:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    pid="$(/usr/bin/grep -m1 '^PID:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    cpu="$(/usr/bin/grep -m1 '^CPU:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    footprint="$(/usr/bin/grep -m1 '^Footprint:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    stack_hint="$(/usr/bin/grep -Em1 'JSC::Heap|JSC::SlotVisitor|JSC::Marking|WebCore::Page::updateRendering|WebKit::WebPage::updateRendering|AnimationTimelinesController|QuartzCore|mediaanalysisd|mobileassetd|replayd' "$report" 2>/dev/null | xargs 2>/dev/null || true)"

    {
      print -r -- "=== report ${count} ==="
      print -r -- "path=$report"
      print -r -- "modified_epoch=$mtime"
      /usr/bin/grep -E -m12 '^(Date/Time|End time|Command|PID|Event|Action taken|CPU|CPU limit|CPU used|CPU duration|Duration|Footprint|Energy):' "$report" 2>/dev/null || true
      [[ -n "$stack_hint" ]] && print -r -- "stack_hint=$stack_hint"
      print -r -- ""
    } >> "$output"

    if (( count == 1 )); then
      MACOS_RESOURCE_REPORT_PATH="$report"
      MACOS_RESOURCE_COMMAND="$command"
      MACOS_RESOURCE_PID="$pid"
      MACOS_RESOURCE_CPU="$cpu"
      MACOS_RESOURCE_FOOTPRINT="$footprint"
      MACOS_RESOURCE_STACK_HINT="$stack_hint"
    fi
    if [[ "$command" == *"WebKit.WebContent"* || "$report:t" == *"WebKit.WebContent"* ]]; then
      MACOS_WEBKIT_RESOURCE_FOUND=1
      if [[ "$MACOS_RESOURCE_COMMAND" != *"WebKit.WebContent"* ]]; then
        MACOS_RESOURCE_REPORT_PATH="$report"
        MACOS_RESOURCE_COMMAND="$command"
        MACOS_RESOURCE_PID="$pid"
        MACOS_RESOURCE_CPU="$cpu"
        MACOS_RESOURCE_FOOTPRINT="$footprint"
        MACOS_RESOURCE_STACK_HINT="$stack_hint"
      fi
    fi
    (( count >= MACOS_RESOURCE_REPORT_MAX_FILES )) && break
  done

  if (( count == 0 )); then
    print -r -- "no-matching-macos-cpu-resource-report" >| "$output"
  fi
}

capture_content_filter_context() {
  local incident_dir="$1" output temp file max_bytes=131072
  output="$incident_dir/content-filter-context.txt"
  temp="$incident_dir/.content-filter-context.tmp"
  if (( CONTENT_FILTER_RUNNING != 1 )) || [[ -z "$CONTENT_FILTER_LOG_DIR" || ! -d "$CONTENT_FILTER_LOG_DIR" ]]; then
    print -r -- "not-configured-running-or-no-readable-log" >| "$output"
    return
  fi

  if (( CAPTURE_SAFARI_DOMAINS != 1 )); then
    {
      print -r -- "captured=$(timestamp)"
      print -r -- "content_filter_running=$CONTENT_FILTER_RUNNING"
      print -r -- "content_filter_cpu_pct=$CONTENT_FILTER_CPU"
      print -r -- "error_lines_with_domains=disabled-by-privacy-setting"
    } >| "$output"
    return
  fi

  {
    print -r -- "captured=$(timestamp)"
    print -r -- "content_filter_running=$CONTENT_FILTER_RUNNING"
    print -r -- "content_filter_cpu_pct=$CONTENT_FILTER_CPU"
    for file in "$CONTENT_FILTER_LOG_DIR"/*.log(N.); do
      print -r -- "--- ${file:t} ---"
      stat -f 'modified: %Sm size_bytes: %z' -t '%Y-%m-%dT%H:%M:%S%z' "$file" 2>/dev/null || true
      tail -n 600 "$file" 2>/dev/null | /usr/bin/grep -Ei 'ERROR|WARN|timeout|disconnect|reset' | tail -n 80 || true
    done
  } >| "$temp"
  head -c "$max_bytes" "$temp" >| "$output"
  rm -f -- "$temp"
}

generate_incident_diagnosis() {
  local incident_dir="$1" reason="$2" timeline output metrics
  local min_free max_compressor max_swap max_safari max_webkit max_ws max_report max_symbol max_content_filter max_webkit_count offline_seen
  local max_webkit_hot hot_pid max_mediaanalysis max_mobileasset max_replay factor_count=0 primary="unresolved"
  local webkit_factor=0 background_factor=0 memory_factor=0 display_factor=0 network_factor=0 classification
  timeline="$incident_dir/timeline.tsv"
  output="$incident_dir/diagnosis.txt"
  metrics="$(awk -F '\t' '
    BEGIN {minfree=101}
    NF >= 37 {
      if (($4+0) < minfree) minfree=$4+0
      if (($6+0) > comp) comp=$6+0
      if (($8+0) > swap) swap=$8+0
      if (($10+0) > safari) safari=$10+0
      if (($11+0) > webkit) webkit=$11+0
      if (($14+0) > ws) ws=$14+0
      if (($27+0) > wc) wc=$27+0
      if (($28+0) > report) report=$28+0
      if (($29+0) > symbol) symbol=$29+0
      if (($30+0) > content_filter) content_filter=$30+0
      if (($31+0) > webkit_hot) {webkit_hot=$31+0; hot_pid=$32+0}
      if (($34+0) > mediaanalysis) mediaanalysis=$34+0
      if (($35+0) > mobileasset) mobileasset=$35+0
      if (($36+0) > replay) replay=$36+0
      if ($19 != "online" && $19 != "disabled") offline=1
    }
    END {printf "%.0f %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.0f %d %.1f %d %.1f %.1f %.1f\n", minfree,comp,swap,safari,webkit,ws,report,symbol,content_filter,wc,offline,webkit_hot,hot_pid,mediaanalysis,mobileasset,replay}
  ' "$timeline" 2>/dev/null)"
  read -r min_free max_compressor max_swap max_safari max_webkit max_ws max_report max_symbol max_content_filter max_webkit_count offline_seen max_webkit_hot hot_pid max_mediaanalysis max_mobileasset max_replay <<< "${metrics:-101 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0}"

  if (( $(integer_value "$max_webkit_hot") >= WEBKIT_CPU_SAMPLE_THRESHOLD || $(integer_value "$max_safari") >= SAFARI_GROUP_MB_THRESHOLD )); then
    webkit_factor=1
    (( factor_count++ ))
    primary="safari-webkit-hot-content"
  fi
  if (( $(integer_value "$max_mediaanalysis") >= MEDIAANALYSISD_CPU_THRESHOLD || $(integer_value "$max_mobileasset") >= MOBILEASSETD_CPU_THRESHOLD || $(integer_value "$max_replay") >= REPLAYD_CPU_THRESHOLD )); then
    background_factor=1
    (( factor_count++ ))
    [[ "$primary" == "unresolved" ]] && primary="macos-background-service-storm"
  fi
  if (( $(integer_value "$min_free") <= MEMORY_FREE_PERCENT_THRESHOLD || $(integer_value "$max_compressor") >= COMPRESSOR_MB_THRESHOLD )); then
    memory_factor=1
    (( factor_count++ ))
    [[ "$primary" == "unresolved" ]] && primary="memory-compression-pressure"
  fi
  if (( $(integer_value "$max_ws") >= WINDOWSERVER_CPU_THRESHOLD )); then
    display_factor=1
    (( factor_count++ ))
    [[ "$primary" == "unresolved" ]] && primary="windowserver-display-load"
  fi
  if (( offline_seen == 1 )); then
    network_factor=1
    (( factor_count++ ))
    [[ "$primary" == "unresolved" ]] && primary="general-network-or-dns-problem"
  fi
  if (( MACOS_WEBKIT_RESOURCE_FOUND == 1 )); then
    primary="probable-webkit-content-runaway"
    classification="probable-webkit-content-runaway"
  elif (( factor_count >= 2 )); then
    classification="multi-factor-resource-contention"
  else
    classification="$primary"
  fi

  {
    print -r -- "MacLagMonitor local diagnosis"
    print -r -- "generated=$(timestamp)"
    print -r -- "trigger_reason=$reason"
    print -r -- ""
    print -r -- "classification=$classification"
    print -r -- "primary_suspect=$primary"
    if (( MACOS_WEBKIT_RESOURCE_FOUND == 1 )); then
      print -r -- "confidence=high"
    elif (( MACOS_RESOURCE_FOUND == 1 )); then
      print -r -- "confidence=medium-high"
    else
      print -r -- "confidence=$([[ "$primary" == "unresolved" ]] && print low || print medium)"
    fi
    print -r -- "contributors=safari_webkit:${webkit_factor},macos_background:${background_factor},memory:${memory_factor},windowserver:${display_factor},network:${network_factor}"
    print -r -- "cross_incident_domain_candidate_found=$DOMAIN_CORRELATION_FOUND"
    if (( DOMAIN_CORRELATION_FOUND == 1 )); then
      print -r -- "cross_incident_domain_candidate=$DOMAIN_CORRELATION_TOP_DOMAIN"
      print -r -- "cross_incident_domain_occurrence=${DOMAIN_CORRELATION_TOP_COUNT}/${DOMAIN_CORRELATION_INCIDENTS_WITH_DOMAINS}"
      print -r -- "cross_incident_domain_hot_capture_count=$DOMAIN_CORRELATION_TOP_HOT_COUNT"
      print -r -- "cross_incident_domain_active_tab_count=$DOMAIN_CORRELATION_TOP_ACTIVE_COUNT"
      print -r -- "cross_incident_domain_association_strength=$DOMAIN_CORRELATION_STRENGTH"
    fi
    print -r -- "macos_cpu_resource_report_found=$MACOS_RESOURCE_FOUND"
    print -r -- "macos_webkit_cpu_resource_report_found=$MACOS_WEBKIT_RESOURCE_FOUND"
    if (( MACOS_RESOURCE_FOUND == 1 )); then
      print -r -- "macos_resource_report=$MACOS_RESOURCE_REPORT_PATH"
      print -r -- "macos_resource_command=$MACOS_RESOURCE_COMMAND"
      print -r -- "macos_resource_pid=$MACOS_RESOURCE_PID"
      print -r -- "macos_resource_cpu=$MACOS_RESOURCE_CPU"
      print -r -- "macos_resource_footprint=$MACOS_RESOURCE_FOOTPRINT"
      print -r -- "macos_resource_stack_hint=$MACOS_RESOURCE_STACK_HINT"
    fi
    if (( MACOS_WEBKIT_RESOURCE_FOUND == 1 && DOMAIN_CORRELATION_FOUND == 1 )); then
      print -r -- "recommended_action=macOS 자체가 WebKit CPU 과다를 기록했고 최근 WebKit 관련 사고에서 '$DOMAIN_CORRELATION_TOP_DOMAIN'이 ${DOMAIN_CORRELATION_TOP_COUNT}/${DOMAIN_CORRELATION_INCIDENTS_WITH_DOMAINS}회 반복됨. 이 도메인 탭부터 격리해 재현 여부를 확인하고, 재발하면 확장·콘텐츠 필터를 하나씩 꺼 비교"
    elif (( MACOS_WEBKIT_RESOURCE_FOUND == 1 )); then
      print -r -- "recommended_action=macOS 자체가 WebKit CPU 과다를 기록함. Safari를 완전 종료 후 재시작하고, 재발 시 사고 시점 도메인 후보에서 탭을 하나씩 격리한 뒤 확장·콘텐츠 필터를 하나씩 꺼 비교"
    elif (( SAFARI_FAULT_FOUND == 1 )); then
      print -r -- "safari_fault_evidence=present"
      print -r -- "recommended_action=Safari를 Command-Q로 재시작하고 hot-webkit 표본 시점의 도메인 후보를 비교; 재발 시 콘텐츠 필터 켬/끔 시험"
    elif (( webkit_factor == 1 )); then
      print -r -- "recommended_action=hot-webkit 표본과 같은 번호의 Safari 도메인 후보를 확인하고, Safari 재시작 전후 및 탭 격리 비교"
    elif (( background_factor == 1 )); then
      print -r -- "recommended_action=mediaanalysisd·mobileassetd·replayd 중 임계값을 넘은 프로세스와 recent-system-events.log의 작업 종류를 확인"
    elif (( network_factor == 1 )); then
      print -r -- "recommended_action=network-events.tsv와 DNS/라우터/Wi-Fi 상태를 먼저 확인"
    elif (( display_factor == 1 )); then
      print -r -- "recommended_action=외부 디스플레이·미러링·주사율 조건을 바꿔 재현 비교"
    else
      print -r -- "recommended_action=자동 해결 근거 부족; 동일 조건의 재현 자료를 추가 확보"
    fi
    print -r -- ""
    print -r -- "observed_min_memory_free_pct=$min_free"
    print -r -- "observed_max_compressor_mb=$max_compressor"
    print -r -- "observed_max_swap_mb=$max_swap"
    print -r -- "observed_max_safari_group_mb=$max_safari"
    print -r -- "observed_max_webkit_total_mb=$max_webkit"
    print -r -- "observed_max_webkit_process_count=$max_webkit_count"
    print -r -- "observed_max_windowserver_cpu_pct=$max_ws"
    print -r -- "observed_max_reportcrash_cpu_pct=$max_report"
    print -r -- "observed_max_coresymbolication_cpu_pct=$max_symbol"
    print -r -- "observed_max_content_filter_cpu_pct=$max_content_filter"
    print -r -- "observed_max_webkit_hot_cpu_pct=$max_webkit_hot"
    print -r -- "observed_webkit_hot_pid=$hot_pid"
    print -r -- "observed_max_mediaanalysisd_cpu_pct=$max_mediaanalysis"
    print -r -- "observed_max_mobileassetd_cpu_pct=$max_mobileasset"
    print -r -- "observed_max_replayd_cpu_pct=$max_replay"
    print -r -- "content_filter_running_at_end=${CONTENT_FILTER_RUNNING:-0}"
    print -r -- "safari_fault_report_found=$SAFARI_FAULT_FOUND"
    print -r -- ""
    print -r -- "limits=이 판정은 관측된 상관관계를 분류하며 Apple WebKit 내부 버그나 특정 확장의 인과관계를 단독으로 증명하지 않음"
  } >| "$output"
  (( $(stat -f '%z' "$output" 2>/dev/null || print 0) > 65536 )) && trim_file_to_bytes "$output" 65536
}

generate_reboot_postmortem() {
  local marker="$STATE_DIR/postmortem-boot-epoch" output="$DATA_DIR/last-reboot-diagnosis.txt"
  local boot_epoch boot_text last_line last_ts last_epoch rows metrics
  local min_free max_compressor max_swap max_safari max_webkit_proc max_ws max_webkit_cpu hot_pid
  local safari_drop compressor_drop swap_drop drop_time report_line report mtime command pid cpu footprint stack_hint
  local report_found=0 webkit_report_found=0 confidence="low" classification="unresolved" action
  local -a ranked

  boot_epoch="$(sysctl -n kern.boottime 2>/dev/null | awk 'match($0,/sec = [0-9]+/){v=substr($0,RSTART+6,RLENGTH-6); print v}')"
  [[ "$boot_epoch" == <-> ]] || return
  [[ -f "$marker" && "$(<"$marker")" == "$boot_epoch" ]] && return
  boot_text="$(date -r "$boot_epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)"
  [[ -n "$boot_text" ]] || { print -r -- "$boot_epoch" >| "$marker"; return; }

  last_line="$(awk -F '\t' -v b="$boot_text" 'NR>1 && $1 < b {line=$0} END{print line}' "$SUMMARY_FILE" 2>/dev/null)"
  [[ -n "$last_line" ]] || { print -r -- "$boot_epoch" >| "$marker"; return; }
  last_ts="${last_line%%$'\t'*}"
  last_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$last_ts" '+%s' 2>/dev/null || true)"
  if [[ "$last_epoch" != <-> ]] || (( boot_epoch - last_epoch > 3600 )); then
    print -r -- "$boot_epoch" >| "$marker"
    return
  fi

  rows="$(awk -F '\t' -v b="$boot_text" -v keep="$REBOOT_POSTMORTEM_ROWS" '
    NR>1 && $1 < b {buf[(n++) % keep]=$0}
    END {
      start=(n>keep?n-keep:0)
      for (i=start; i<n; i++) print buf[i % keep]
    }
  ' "$SUMMARY_FILE" 2>/dev/null)"

  metrics="$(print -r -- "$rows" | awk -F '\t' '
    BEGIN {minfree=101; prevSafari=-1}
    NF >= 37 {
      if (($4+0) < minfree) minfree=$4+0
      if (($6+0) > comp) comp=$6+0
      if (($8+0) > swap) swap=$8+0
      if (($10+0) > safari) safari=$10+0
      if (($12+0) > webproc) webproc=$12+0
      if (($14+0) > ws) ws=$14+0
      if (($31+0) > whot) {whot=$31+0; hotpid=$32+0}
      if (prevSafari >= 0) {
        sd=prevSafari-($10+0); cd=prevComp-($6+0); swd=prevSwap-($8+0)
        if (sd > maxsd) {maxsd=sd; maxcd=cd; maxswd=swd; droptime=$1}
      }
      prevSafari=$10+0; prevComp=$6+0; prevSwap=$8+0
    }
    END {printf "%.0f %.1f %.1f %.1f %.1f %.1f %.1f %d %.1f %.1f %.1f %s\n",minfree,comp,swap,safari,webproc,ws,whot,hotpid,maxsd,maxcd,maxswd,droptime}
  ')"
  read -r min_free max_compressor max_swap max_safari max_webkit_proc max_ws max_webkit_cpu hot_pid safari_drop compressor_drop swap_drop drop_time <<< "${metrics:-101 0 0 0 0 0 0 0 0 0 0 -}"

  ranked=("${(@f)$(find "$DIAGNOSTIC_REPORTS_DIR" "$SYSTEM_DIAGNOSTIC_REPORTS_DIR" -maxdepth 1 -type f -name '*.cpu_resource.diag' -print0 2>/dev/null \
    | xargs -0 stat -f $'%m\t%N' 2>/dev/null | sort -rn 2>/dev/null)}")
  for report_line in "${ranked[@]}"; do
    mtime="${report_line%%$'\t'*}"
    report="${report_line#*$'\t'}"
    [[ "$mtime" == <-> && -f "$report" ]] || continue
    (( mtime >= boot_epoch - 10800 && mtime <= boot_epoch )) || continue
    command="$(/usr/bin/grep -m1 '^Command:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    [[ "$command" == *"WebKit.WebContent"* || "$report:t" == *"WebKit.WebContent"* ]] || continue
    report_found=1
    webkit_report_found=1
    pid="$(/usr/bin/grep -m1 '^PID:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    cpu="$(/usr/bin/grep -m1 '^CPU:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    footprint="$(/usr/bin/grep -m1 '^Footprint:' "$report" 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"
    stack_hint="$(/usr/bin/grep -Em1 'JSC::Heap|JSC::SlotVisitor|JSC::Marking|WebCore::Page::updateRendering|WebKit::WebPage::updateRendering|AnimationTimelinesController' "$report" 2>/dev/null | xargs 2>/dev/null || true)"
    break
  done

  if (( webkit_report_found == 1 )) && (( $(integer_value "$safari_drop") >= 4096 )) && (( $(integer_value "$compressor_drop") >= 1024 )); then
    classification="probable-webkit-content-runaway-with-memory-pressure"
    confidence="high"
    action="Safari/WebKit 폭주가 가장 유력. Safari 완전 종료로 회복되는지 우선 확인하고, 재발 incident의 도메인 후보를 비교해 공통 탭을 격리한 뒤 확장·콘텐츠 필터를 하나씩 꺼 재현 비교"
  elif (( webkit_report_found == 1 )); then
    classification="probable-webkit-content-runaway"
    confidence="high"
    action="macOS가 WebKit CPU 과다를 독립적으로 기록함. 재발 시 사고 시점 도메인 후보와 hot WebKit PID를 우선 대조하고 Safari 재시작 전후를 비교"
  elif (( $(integer_value "$max_compressor") >= COMPRESSOR_MB_THRESHOLD )); then
    classification="memory-compression-pressure"
    confidence="medium"
    action="재부팅 전 압축 메모리가 높았음. 다음 재발 incident에서 어떤 앱 그룹 증가가 compressor 상승과 같이 움직이는지 확인"
  elif (( $(integer_value "$max_ws") >= WINDOWSERVER_CPU_THRESHOLD )); then
    classification="windowserver-display-load"
    confidence="medium"
    action="외부 디스플레이·미러링·주사율 조건을 바꿔 재현 여부를 비교"
  else
    action="자동 사후분석 근거가 부족함. 다음 incident의 macOS resource report와 도메인 후보를 함께 확인"
  fi

  {
    print -r -- "MacLagMonitor reboot postmortem"
    print -r -- "generated=$(timestamp)"
    print -r -- "current_boot=$boot_text"
    print -r -- "last_preboot_sample=$last_ts"
    print -r -- "classification=$classification"
    print -r -- "confidence=$confidence"
    print -r -- "recommended_action=$action"
    print -r -- ""
    print -r -- "preboot_min_memory_free_pct=$min_free"
    print -r -- "preboot_max_compressor_mb=$max_compressor"
    print -r -- "preboot_max_swap_mb=$max_swap"
    print -r -- "preboot_max_safari_group_mb=$max_safari"
    print -r -- "preboot_max_webkit_process_mb=$max_webkit_proc"
    print -r -- "preboot_max_windowserver_cpu_pct=$max_ws"
    print -r -- "preboot_max_webkit_hot_cpu_pct=$max_webkit_cpu"
    print -r -- "preboot_webkit_hot_pid=$hot_pid"
    print -r -- "largest_safari_drop_mb=$safari_drop"
    print -r -- "compressor_drop_at_same_transition_mb=$compressor_drop"
    print -r -- "swap_drop_at_same_transition_mb=$swap_drop"
    print -r -- "recovery_transition_time=${drop_time:--}"
    print -r -- ""
    print -r -- "macos_webkit_cpu_resource_report_found=$webkit_report_found"
    if (( report_found == 1 )); then
      print -r -- "macos_resource_report=$report"
      print -r -- "macos_resource_command=$command"
      print -r -- "macos_resource_pid=$pid"
      print -r -- "macos_resource_cpu=$cpu"
      print -r -- "macos_resource_footprint=$footprint"
      print -r -- "macos_resource_stack_hint=$stack_hint"
    fi
    print -r -- ""
    print -r -- "limits=사후분석은 높은 상관성과 macOS 자체 resource 진단을 결합하지만 특정 웹사이트·확장·WebKit 버그의 인과를 단독으로 증명하지 않음"
  } >| "$output"
  print -r -- "$boot_epoch" >| "$marker"
  log_message "reboot-postmortem classification=$classification confidence=$confidence"
}

send_local_notification() {
  (( LOCAL_NOTIFICATION_ENABLED == 1 )) || return
  osascript -e 'display notification "성능 이상 징후를 감지해 로컬 상세 기록을 시작했습니다." with title "MacLagMonitor"' >/dev/null 2>&1 || true
}

run_incident_capture() {
  local reason="$1" start end now incident_id incident_file base_lines sample_started remaining
  local webkit_sample_count=0 webkit_last_sample_epoch=0
  start="$(epoch_now)"
  end=$(( start + INCIDENT_DURATION_SECONDS ))
  incident_id="$(date '+%Y%m%d-%H%M%S')"
  CURRENT_INCIDENT_DIR="$INCIDENTS_DIR/$incident_id"
  mkdir -p "$CURRENT_INCIDENT_DIR"
  incident_file="$CURRENT_INCIDENT_DIR/timeline.tsv"
  ensure_summary_header
  base_lines=$(( PRE_TRIGGER_MINUTES * 60 / AC_INTERVAL_SECONDS + 20 ))
  {
    head -n 1 "$SUMMARY_FILE"
    tail -n "$base_lines" "$SUMMARY_FILE"
  } >| "$CURRENT_INCIDENT_DIR/summary-before-trigger.tsv" 2>/dev/null || true

  {
    print -r -- "incident_id=$incident_id"
    print -r -- "monitor_version=$(<"$INSTALL_ROOT/VERSION")"
    print -r -- "started=$(timestamp)"
    print -r -- "reason=$reason"
    print -r -- "incident_interval_seconds=$INCIDENT_INTERVAL_SECONDS"
    print -r -- "incident_duration_seconds=$INCIDENT_DURATION_SECONDS"
    print -r -- "privacy_safari_domains=$CAPTURE_SAFARI_DOMAINS"
    print -r -- "external_internet_checks=$INTERNET_CHECK_ENABLED"
  } >| "$CURRENT_INCIDENT_DIR/metadata.txt"

  log_message "incident-start id=$incident_id reason=$reason"
  send_local_notification
  capture_detailed_state "$CURRENT_INCIDENT_DIR" "start"

  while (( $(epoch_now) < end )) && (( STOP_REQUESTED == 0 )); do
    sample_started="$(epoch_now)"
    collect_and_write_snapshot "$INCIDENT_INTERVAL_SECONDS" "$incident_file"
    now="$(epoch_now)"
    if (( webkit_sample_count < PROCESS_SAMPLE_MAX_PER_INCIDENT )) && \
      (( now - webkit_last_sample_epoch >= PROCESS_SAMPLE_COOLDOWN_SECONDS )) && \
      (( $(integer_value "$WEBKIT_HOT_CPU") >= WEBKIT_CPU_SAMPLE_THRESHOLD )); then
      (( webkit_sample_count++ ))
      if capture_hot_webkit_sample "$CURRENT_INCIDENT_DIR" "$webkit_sample_count"; then
        webkit_last_sample_epoch="$(epoch_now)"
      else
        (( webkit_sample_count-- ))
      fi
    fi
    remaining=$(( INCIDENT_INTERVAL_SECONDS - ($(epoch_now) - sample_started) ))
    (( remaining > 0 )) && interruptible_sleep "$remaining"
  done

  capture_detailed_state "$CURRENT_INCIDENT_DIR" "end"
  capture_recent_system_logs_if_relevant "$CURRENT_INCIDENT_DIR" "$start" "$(epoch_now)" "$reason"
  capture_safari_fault_reports "$CURRENT_INCIDENT_DIR"
  capture_macos_resource_reports "$CURRENT_INCIDENT_DIR" "$start" "$(epoch_now)"
  capture_content_filter_context "$CURRENT_INCIDENT_DIR"
  generate_cross_incident_domain_correlation "$CURRENT_INCIDENT_DIR" "$reason"
  generate_incident_diagnosis "$CURRENT_INCIDENT_DIR" "$reason"
  print -r -- "ended=$(timestamp)" >> "$CURRENT_INCIDENT_DIR/metadata.txt"
  log_message "incident-end id=$incident_id"
  CURRENT_INCIDENT_DIR=""
  print -r -- "0" >| "$STATE_DIR/trigger.count"
  maybe_rotate_storage 1
}

update_episode_state() {
  local group="$1" anomaly_present="$2"
  local active_file="$STATE_DIR/episode-${group}.active"
  local recovery_file="$STATE_DIR/episode-${group}.recovery" count=0
  if [[ -f "$active_file" ]]; then
    if (( anomaly_present == 1 )); then
      print -r -- "0" >| "$recovery_file"
      print -r -- "1"
    else
      [[ -f "$recovery_file" ]] && count="$(<"$recovery_file")"
      [[ "$count" == <-> ]] || count=0
      (( count++ ))
      if (( count >= PERFORMANCE_EPISODE_RECOVERY_SAMPLES )); then
        rm -f -- "$active_file" "$recovery_file"
        log_message "episode-rearmed group=$group"
        print -r -- "0"
      else
        print -r -- "$count" >| "$recovery_file"
        print -r -- "1"
      fi
    fi
  else
    print -r -- "0"
  fi
}

mark_episode_active() {
  local group="$1"
  print -r -- "$(timestamp)" >| "$STATE_DIR/episode-${group}.active"
  print -r -- "0" >| "$STATE_DIR/episode-${group}.recovery"
}

handle_trigger_state() {
  local flags="$1" count=0 performance_present=0 crash_present=0
  local performance_active crash_active flag candidate_flags
  local -a raw_flags candidates
  [[ -f "$STATE_DIR/trigger.count" ]] && count="$(<"$STATE_DIR/trigger.count")"
  [[ "$count" == <-> ]] || count=0

  raw_flags=("${(@s:,:)flags}")
  for flag in "${raw_flags[@]}"; do
    case "$flag" in
      memory-pressure|compressor-high|safari-high|webkit-process-high|webkit-cpu-high|windowserver-high|mediaanalysisd-high|mobileassetd-high|replayd-high|system-load-high|monitor-sample-stall)
        performance_present=1
        ;;
      crashreporter-high|coresymbolication-high)
        crash_present=1
        ;;
    esac
  done

  performance_active="$(update_episode_state performance "$performance_present")"
  crash_active="$(update_episode_state crash "$crash_present")"

  for flag in "${raw_flags[@]}"; do
    case "$flag" in
      manual-test|internet-down|monitor-sample-stall)
        candidates+=("$flag")
        ;;
      crashreporter-high|coresymbolication-high)
        (( crash_active == 0 )) && candidates+=("$flag")
        ;;
      memory-pressure|compressor-high|safari-high|webkit-process-high|webkit-cpu-high|windowserver-high|mediaanalysisd-high|mobileassetd-high|replayd-high|system-load-high)
        (( performance_active == 0 )) && candidates+=("$flag")
        ;;
    esac
  done
  candidate_flags="${(j:,:)candidates}"

  if [[ -n "$candidate_flags" ]]; then
    if [[ "$candidate_flags" == *"manual-test"* || "$candidate_flags" == *"internet-down"* || "$candidate_flags" == *"monitor-sample-stall"* || \
      "$candidate_flags" == *"crashreporter-high"* || "$candidate_flags" == *"coresymbolication-high"* ]]; then
      count="$CONSECUTIVE_TRIGGER_SAMPLES"
    else
      (( count++ ))
    fi
  else
    count=0
  fi
  print -r -- "$count" >| "$STATE_DIR/trigger.count"

  if (( count >= CONSECUTIVE_TRIGGER_SAMPLES )); then
    (( performance_present == 1 && performance_active == 0 )) && mark_episode_active performance
    (( crash_present == 1 && crash_active == 0 )) && mark_episode_active crash
    run_incident_capture "$candidate_flags"
  fi
}

run_once() {
  local power interval
  power="$(current_power_mode)"
  interval="$(choose_interval "$power")"
  collect_and_write_snapshot "$interval" "" "$power"
  maybe_rotate_storage
  print -r -- "snapshot=$(timestamp) flags=${CONTEXT_FLAGS:-none} incident_flags=${TRIGGER_FLAGS:-none}"
}

main_loop() {
  local power interval free_disk
  print -r -- "$$" >| "$PID_FILE"
  OWNS_PID_FILE=1
  generate_reboot_postmortem
  log_message "monitor-start pid=$$"
  while (( STOP_REQUESTED == 0 )); do
    power="$(current_power_mode)"
    interval="$(choose_interval "$power")"
    free_disk="$(df -km /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4+0}')"
    if (( free_disk > 0 && free_disk < MIN_FREE_DISK_MB )); then
      interval="$LOW_POWER_INTERVAL_SECONDS"
      maybe_rotate_storage 1
      log_message "low-disk free_mb=$free_disk minimal-mode=1"
    fi

    collect_and_write_snapshot "$interval" "" "$power"
    handle_trigger_state "$TRIGGER_FLAGS"
    maybe_rotate_storage
    interruptible_sleep "$interval"
  done
}

case "${1:-run}" in
  run)
    main_loop
    ;;
  --once)
    run_once
    ;;
  --force-incident)
    FORCE_TRIGGER=1
    run_once
    run_incident_capture "manual-test"
    ;;
  *)
    print -u2 -- "Usage: $0 [run|--once|--force-incident]"
    exit 2
    ;;
esac
