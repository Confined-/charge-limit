#!/bin/bash
set -u

SYSFS="/sys/class/power_supply"
HELPER_BIN="/usr/local/bin/battery-charge-limit"
DRY_RUN="${CHARGE_LIMIT_DRY_RUN:-}"
VERSION="7"

if [ "$(id -u)" -eq 0 ]; then
  SYSFS="/sys/class/power_supply"
  DRY_RUN=""
elif [ -n "${CHARGE_LIMIT_TEST_MODE:-}" ] && [ -n "${BATTERY_SYSFS:-}" ]; then
  SYSFS="$BATTERY_SYSFS"
fi

cmd_version() {
  printf '{"ok":true,"version":"%s"}\n' "$VERSION"
}

granted_probe() {
  [ -x "$HELPER_BIN" ] || return 1
  sudo -n -l -- "$HELPER_BIN" set 80 70 >/dev/null 2>&1
}

usage() {
  printf 'Usage: battery-charge-limit get | set <20-100> | save-state <20-100> | boot-pref on|off\n' >&2
  exit 2
}

json_escape() {
  local s=$1
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

batteries_with_end_threshold() {
  local d
  for d in "$SYSFS"/BAT*; do
    [ -e "$d/charge_control_end_threshold" ] && printf '%s\n' "$d"
  done
}

read_int() {
  tr -cd '0-9' < "$1" 2>/dev/null
}

is_charging_status() {
  case $1 in
    Charging) return 0 ;;
    *) return 1 ;;
  esac
}

battery_json() {
  local dir=$1
  local end start cap status
  end=$(read_int "$dir/charge_control_end_threshold")
  if [ -e "$dir/charge_control_start_threshold" ]; then
    start=$(read_int "$dir/charge_control_start_threshold")
  else
    start=""
  fi
  cap=$(read_int "$dir/capacity")
  status=$(cat "$dir/status" 2>/dev/null || printf 'Unknown')
  printf '{"name":%s,"end":%s,"start":%s,"capacity":%s,"status":%s,"charging":%s}' \
    "$(json_escape "${dir##*/}")" \
    "${end:-null}" \
    "${start:-null}" \
    "${cap:-null}" \
    "$(json_escape "$status")" \
    "$(is_charging_status "$status" && echo true || echo false)"
}

fetch_deployed_version() {
  local installed=$1
  if [ "$installed" != true ]; then
    printf 'null'
    return
  fi
  local v
  v=$("$HELPER_BIN" version 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  if [ -n "$v" ]; then
    json_escape "$v"
  else
    printf 'null'
  fi
}

collect_battery_payload() {
  local batteries="" count=0
  local first_pct=-1 first_status="Unknown"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    count=$((count + 1))
    batteries="$batteries$( [ $count -gt 1 ] && echo , )$(battery_json "$dir")"
    if [ "$first_pct" = "-1" ]; then
      first_pct=$(read_int "$dir/capacity" 2>/dev/null)
      first_status=$(cat "$dir/status" 2>/dev/null || printf 'Unknown')
    fi
  done < <(batteries_with_end_threshold)
  printf '%s|%s|%s|%s' "$batteries" "$count" "$first_pct" "$first_status"
}

emit_empty_get() {
  local installed=$1 version=$2
  printf '{"ok":true,"installed":%s,"version":%s,"supported":false,"pct":-1,"charging":false,"batteries":[]}\n' "$installed" "$version"
}

emit_populated_get() {
  local installed=$1 version=$2 batteries=$3 pct=$4 status=$5
  local charging=false
  is_charging_status "$status" && charging=true
  printf '{"ok":true,"installed":%s,"version":%s,"supported":true,"pct":%s,"charging":%s,"batteries":[%s]}\n' \
    "$installed" "$version" "${pct:--1}" "$charging" "$batteries"
}

cmd_get() {
  local installed=false
  granted_probe && installed=true
  local version
  version=$(fetch_deployed_version "$installed")
  local payload batteries count pct status
  payload=$(collect_battery_payload)
  IFS='|' read -r batteries count pct status <<< "$payload"
  if [ "$count" -eq 0 ]; then
    emit_empty_get "$installed" "$version"
    exit 0
  fi
  emit_populated_get "$installed" "$version" "$batteries" "$pct" "$status"
}

validate_value() {
  local value=$1
  case $value in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 20 ] && [ "$value" -le 100 ]
}

validate_start_for_set() {
  local start=$1 end=$2
  [ -n "$start" ] || return 0
  case $start in
    ''|*[!0-9]*)
      printf '{"ok":false,"error":"lower limit must be an integer"}\n'
      return 2
      ;;
  esac
  if [ "$start" -gt 100 ]; then
    printf '{"ok":false,"error":"lower limit must be at most 100"}\n'
    return 2
  fi
  if [ "$start" -ge "$end" ]; then
    printf '{"ok":false,"error":"lower limit must be below the upper limit"}\n'
    return 2
  fi
}

validate_set_args() {
  local end=$1 start=$2
  if ! validate_value "$end"; then
    printf '{"ok":false,"error":"upper limit must be an integer between 20 and 100"}\n'
    return 2
  fi
  validate_start_for_set "$start" "$end"
}

check_real_sysfs_privilege() {
  if [ "$SYSFS" = "/sys/class/power_supply" ] && [ "$(id -u)" -ne 0 ]; then
    printf '{"ok":false,"error":"not running as root"}\n'
    return 1
  fi
}

is_allowed_pair() {
  if [ "$1" = "80" ] && [ "$2" = "70" ]; then
    return 0
  fi
  [ "$1" = "100" ] && [ "$2" = "0" ]
}

check_allowed_literal_pair() {
  local end=$1 start=$2
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi
  if is_allowed_pair "$end" "$start"; then
    return 0
  fi
  printf '{"ok":false,"error":"only the pairs 80 70 and 100 0 are permitted"}\n'
  return 2
}

write_attr() {
  local file=$1 value=$2
  if [ -n "$DRY_RUN" ]; then
    printf 'dry-run: echo %s > %s\n' "$value" "$file" >&2
    return 0
  fi
  echo "$value" > "$file" 2>/dev/null
}

restore_attr() {
  local file=$1 value=$2
  [ -n "$value" ] || return 0
  echo "$value" > "$file" 2>/dev/null
}

need_end_first_for_pair() {
  [ -n "${2:-}" ] && [ "$1" -ge "$2" ]
}

should_auto_lower() {
  local old_start=$1 new_end=$2 start_file=$3
  [ -e "$start_file" ] || return 1
  [ -n "$old_start" ] || return 1
  [ "$old_start" -gt 0 ] || return 1
  [ "$old_start" -ge "$new_end" ]
}

APPLIED_START=""

write_explicit_pair() {
  local dir=$1 new_end=$2 new_start=$3 old_end=$4 old_start=$5
  if need_end_first_for_pair "$new_start" "$old_end"; then
    write_attr "$dir/charge_control_end_threshold" "$new_end" || return 1
    write_attr "$dir/charge_control_start_threshold" "$new_start" || {
      restore_attr "$dir/charge_control_end_threshold" "$old_end"
      return 1
    }
  else
    write_attr "$dir/charge_control_start_threshold" "$new_start" || return 1
    write_attr "$dir/charge_control_end_threshold" "$new_end" || {
      restore_attr "$dir/charge_control_start_threshold" "$old_start"
      return 1
    }
  fi
  APPLIED_START=$new_start
}

write_auto_pair() {
  local dir=$1 new_end=$2 old_start=$3
  local auto_start=$((new_end - 5))
  [ "$auto_start" -lt 0 ] && auto_start=0
  write_attr "$dir/charge_control_start_threshold" "$auto_start" || return 1
  APPLIED_START=$auto_start
  if ! write_attr "$dir/charge_control_end_threshold" "$new_end"; then
    restore_attr "$dir/charge_control_start_threshold" "$old_start"
    APPLIED_START=""
    return 1
  fi
}

write_pair() {
  local dir=$1 new_end=$2 new_start=$3
  local old_start="" old_end=""
  old_end=$(read_int "$dir/charge_control_end_threshold")
  [ -e "$dir/charge_control_start_threshold" ] && old_start=$(read_int "$dir/charge_control_start_threshold")
  if [ -n "$new_start" ]; then
    write_explicit_pair "$dir" "$new_end" "$new_start" "$old_end" "$old_start"
    return $?
  fi
  if should_auto_lower "$old_start" "$new_end" "$dir/charge_control_start_threshold"; then
    write_auto_pair "$dir" "$new_end" "$old_start"
    return $?
  fi
  write_attr "$dir/charge_control_end_threshold" "$new_end"
}

write_pair_explicit() {
  write_explicit_pair "$@"
}

write_pair_auto_lower() {
  write_auto_pair "$@"
}

should_restore_start_first() {
  local old_end=$1 cur_start=$2
  [ -n "$cur_start" ] && [ "$old_end" -le "$cur_start" ]
}

verify_restore_pair() {
  local dir=$1 old_start=$2 old_end=$3
  local now_end now_start=""
  now_end=$(read_int "$dir/charge_control_end_threshold")
  [ -e "$dir/charge_control_start_threshold" ] && now_start=$(read_int "$dir/charge_control_start_threshold")
  [ "$now_end" = "$old_end" ] || return 1
  if [ -n "$old_start" ]; then
    [ "$now_start" = "$old_start" ] || return 1
  fi
  return 0
}

restore_pair() {
  local dir=$1 old_start=$2 old_end=$3
  local start_file="$dir/charge_control_start_threshold"
  local end_file="$dir/charge_control_end_threshold"
  [ -n "$old_end" ] || return 0
  local cur_end cur_start=""
  cur_end=$(read_int "$end_file")
  [ -e "$start_file" ] && cur_start=$(read_int "$start_file")
  if should_restore_start_first "$old_end" "$cur_start"; then
    write_attr "$start_file" "$old_start" || return 1
    write_attr "$end_file" "$old_end" || return 1
  else
    write_attr "$end_file" "$old_end" || return 1
    write_attr "$start_file" "$old_start" || return 1
  fi
  verify_restore_pair "$dir" "$old_start" "$old_end"
}

collect_battery_dirs() {
  batteries_with_end_threshold
}

emit_no_battery_error() {
  printf '{"ok":false,"error":"no battery with a charge limit is present"}\n'
  exit 1
}

try_write_one_battery() {
  local dir=$1 end=$2 start=$3
  SET_OLD_END=$(read_int "$dir/charge_control_end_threshold")
  SET_OLD_START=""
  [ -e "$dir/charge_control_start_threshold" ] && SET_OLD_START=$(read_int "$dir/charge_control_start_threshold")
  APPLIED_START=""
  if write_pair "$dir" "$end" "$start"; then
    local name=${dir##*/}
    SET_DETAILS="$SET_DETAILS{\"name\":$(json_escape "$name"),\"end\":$end,\"start\":$( [ -n "$APPLIED_START" ] && printf '%s' "$APPLIED_START" || printf 'null' )},"
    SET_UNDO_DIRS+=("$dir")
    SET_UNDO_STARTS+=("$SET_OLD_START")
    SET_UNDO_ENDS+=("$SET_OLD_END")
  else
    local name=${dir##*/}
    SET_DETAILS="$SET_DETAILS{\"name\":$(json_escape "$name"),\"error\":\"kernel rejected the value\"},"
    SET_ERRORS=$((SET_ERRORS + 1))
  fi
}

perform_rollback_if_needed() {
  local details=$1 errors=$2
  if [ "$errors" -eq 0 ]; then
    return 1
  fi
  local restore_failures=0
  local i
  for i in "${!SET_UNDO_DIRS[@]}"; do
    if ! restore_pair "${SET_UNDO_DIRS[$i]}" "${SET_UNDO_STARTS[$i]}" "${SET_UNDO_ENDS[$i]}"; then
      restore_failures=$((restore_failures + 1))
    fi
  done
  details=${details%,}
  if [ "$restore_failures" -gt 0 ]; then
    printf '{"ok":false,"error":"one or more batteries rejected the value; rollback was incomplete","batteries":[%s]}\n' "$details"
  else
    printf '{"ok":false,"error":"one or more batteries rejected the value; applied changes were rolled back","batteries":[%s]}\n' "$details"
  fi
  exit 3
}

cmd_set() {
  local end=${1:-}
  local start=${2:-}
  validate_set_args "$end" "$start" || exit $?
  check_real_sysfs_privilege || exit $?
  check_allowed_literal_pair "$end" "$start" || exit $?
  local dirs=()
  local dir
  while IFS= read -r dir; do
    [ -n "$dir" ] && dirs+=("$dir")
  done < <(collect_battery_dirs)
  if [ "${#dirs[@]}" -eq 0 ]; then
    emit_no_battery_error
  fi
  SET_DETAILS=""
  SET_ERRORS=0
  SET_UNDO_DIRS=()
  SET_UNDO_STARTS=()
  SET_UNDO_ENDS=()
  for dir in "${dirs[@]}"; do
    try_write_one_battery "$dir" "$end" "$start"
  done
  perform_rollback_if_needed "$SET_DETAILS" "$SET_ERRORS" && return
  local details=${SET_DETAILS%,}
  printf '{"ok":true,"batteries":[%s]}\n' "$details"
}

state_dir() {
  printf '%s/battery-charge-limit' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

cmd_save_state() {
  local state=${1:-}
  if [ "$(id -u)" -eq 0 ]; then
    printf '{"ok":false,"error":"refusing to write user state as root"}\n'
    exit 1
  fi
  case $state in
    on|off) ;;
    *)
      printf '{"ok":false,"error":"state must be on or off"}\n'
      exit 2
      ;;
  esac
  mkdir -p "$(state_dir)"
  printf '%s\n' "$state" > "$(state_dir)/limit"
  printf '{"ok":true}\n'
}

cmd_boot_pref() {
  local pref=${1:-}
  if [ "$(id -u)" -eq 0 ]; then
    printf '{"ok":false,"error":"refusing to write user state as root"}\n'
    exit 1
  fi
  mkdir -p "$(state_dir)"
  case $pref in
    on) touch "$(state_dir)/apply-at-boot" ;;
    off) rm -f "$(state_dir)/apply-at-boot" ;;
    *) usage ;;
  esac
  printf '{"ok":true}\n'
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

[ $# -ge 1 ] || usage

case $1 in
  get) shift; cmd_get "$@" ;;
  set) shift; cmd_set "$@" ;;
  save-state) shift; cmd_save_state "$@" ;;
  boot-pref) shift; cmd_boot_pref "$@" ;;
  version) shift; cmd_version "$@" ;;
  *) usage ;;
esac
