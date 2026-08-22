#!/bin/bash
set -u

SYSFS="/sys/class/power_supply"
HELPER_BIN="/usr/local/bin/battery-charge-limit"
DRY_RUN="${CHARGE_LIMIT_DRY_RUN:-}"
VERSION="4"

if [ "$(id -u)" -eq 0 ]; then
  SYSFS="/sys/class/power_supply"
  DRY_RUN=""
elif [ -n "${BATTERY_SYSFS:-}" ]; then
  SYSFS="$BATTERY_SYSFS"
fi

cmd_version() {
  printf '{"ok":true,"version":"%s"}\n' "$VERSION"
}

granted_probe() {
  [ -x "$HELPER_BIN" ] || return 1
  if sudo -n -l -- "$HELPER_BIN" set 80 70 >/dev/null 2>&1; then
    return 0
  fi
  return 1
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

cmd_get() {
  local installed=false
  granted_probe && installed=true

  local deployed_version="null"
  if [ "$installed" = true ]; then
    local v
    v=$("$HELPER_BIN" version 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    [ -n "$v" ] && deployed_version="$(json_escape "$v")"
  fi

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

  if [ "$count" -eq 0 ]; then
    printf '{"ok":true,"installed":%s,"version":%s,"supported":false,"pct":-1,"charging":false,"batteries":[]}\n' "$installed" "$deployed_version"
    exit 0
  fi

  printf '{"ok":true,"installed":%s,"version":%s,"supported":true,"pct":%s,"charging":%s,"batteries":[%s]}\n' \
    "$installed" \
    "$deployed_version" \
    "${first_pct:--1}" \
    "$(is_charging_status "$first_status" && echo true || echo false)" \
    "$batteries"
}

validate_value() {
  local value=$1
  case $value in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 20 ] && [ "$value" -le 100 ]
}

write_attr() {
  local file=$1 value=$2
  if [ -n "$DRY_RUN" ]; then
    printf 'dry-run: echo %s > %s\n' "$value" "$file" >&2
    return 0
  fi
  echo "$value" > "$file" 2>/dev/null
}

APPLIED_START=""

restore_attr() {
  local file=$1 value=$2
  [ -n "$value" ] || return 0
  echo "$value" > "$file" 2>/dev/null
}

write_pair() {
  local dir=$1 new_end=$2 new_start=$3
  local start_file="$dir/charge_control_start_threshold"
  local end_file="$dir/charge_control_end_threshold"
  local old_start="" old_end=""
  old_end=$(read_int "$end_file")
  [ -e "$start_file" ] && old_start=$(read_int "$start_file")

  if [ -n "$new_start" ]; then
    if [ -n "$old_end" ] && [ "$new_start" -gt "$old_end" ]; then
      write_attr "$end_file" "$new_end" || return 1
      if ! write_attr "$start_file" "$new_start"; then
        restore_attr "$end_file" "$old_end"
        return 1
      fi
    else
      write_attr "$start_file" "$new_start" || return 1
      if ! write_attr "$end_file" "$new_end"; then
        restore_attr "$start_file" "$old_start"
        return 1
      fi
    fi
    APPLIED_START=$new_start
    return 0
  fi

  if [ -e "$start_file" ] && [ -n "$old_start" ] && [ "$old_start" -gt 0 ] && [ "$old_start" -ge "$new_end" ]; then
    local auto_start=$((new_end - 5))
    [ "$auto_start" -lt 0 ] && auto_start=0
    write_attr "$start_file" "$auto_start" || return 1
    APPLIED_START=$auto_start
    if ! write_attr "$end_file" "$new_end"; then
      restore_attr "$start_file" "$old_start"
      APPLIED_START=""
      return 1
    fi
    return 0
  fi

  write_attr "$end_file" "$new_end" || return 1
}

cmd_set() {
  local end=${1:-}
  local start=${2:-}

  if ! validate_value "$end"; then
    printf '{"ok":false,"error":"upper limit must be an integer between 20 and 100"}\n'
    exit 2
  fi
  if [ -n "$start" ]; then
    case $start in
      ''|*[!0-9]*)
        printf '{"ok":false,"error":"lower limit must be an integer"}\n'
        exit 2
        ;;
    esac
    if [ "$start" -gt 100 ]; then
      printf '{"ok":false,"error":"lower limit must be at most 100"}\n'
      exit 2
    fi
    if [ "$start" -ge "$end" ]; then
      printf '{"ok":false,"error":"lower limit must be below the upper limit"}\n'
      exit 2
    fi
  fi

  if [ "$SYSFS" = "/sys/class/power_supply" ] && [ "$(id -u)" -ne 0 ]; then
    printf '{"ok":false,"error":"not running as root"}\n'
    exit 1
  fi

  local dirs=()
  local dir
  while IFS= read -r dir; do
    [ -n "$dir" ] && dirs+=("$dir")
  done < <(batteries_with_end_threshold)

  if [ "${#dirs[@]}" -eq 0 ]; then
    printf '{"ok":false,"error":"no battery with a charge limit is present"}\n'
    exit 1
  fi

  local errors=0 details=""
  local undo_dirs=()
  local undo_old_starts=()
  local undo_old_ends=()
  local i name old_start old_end

  for dir in "${dirs[@]}"; do
    name=${dir##*/}
    old_end=$(read_int "$dir/charge_control_end_threshold")
    old_start=""
    [ -e "$dir/charge_control_start_threshold" ] && old_start=$(read_int "$dir/charge_control_start_threshold")

    APPLIED_START=""
    if write_pair "$dir" "$end" "$start"; then
      details="$details{\"name\":$(json_escape "$name"),\"end\":$end,\"start\":$( [ -n "$APPLIED_START" ] && printf '%s' "$APPLIED_START" || printf 'null' )},"
      undo_dirs+=("$dir")
      undo_old_starts+=("$old_start")
      undo_old_ends+=("$old_end")
    else
      errors=$((errors + 1))
      details="$details{\"name\":$(json_escape "$name"),\"error\":\"kernel rejected the value\"},"
    fi
  done

  if [ "$errors" -gt 0 ]; then
    for i in "${!undo_dirs[@]}"; do
      restore_attr "${undo_dirs[$i]}/charge_control_end_threshold" "${undo_old_ends[$i]}"
      restore_attr "${undo_dirs[$i]}/charge_control_start_threshold" "${undo_old_starts[$i]}"
    done
    details=${details%,}
    printf '{"ok":false,"error":"one or more batteries rejected the value; applied changes were rolled back","batteries":[%s]}\n' "$details"
    exit 3
  fi

  details=${details%,}
  printf '{"ok":true,"batteries":[%s]}\n' "$details"
}

state_dir() {
  printf '%s/battery-charge-limit' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

cmd_save_state() {
  local end=${1:-}
  local start=${2:-}
  if [ "$(id -u)" -eq 0 ]; then
    printf '{"ok":false,"error":"refusing to write user state as root"}\n'
    exit 1
  fi
  if ! validate_value "$end"; then
    printf '{"ok":false,"error":"invalid state value"}\n'
    exit 2
  fi
  case $start in
    '') start=0 ;;
    *[!0-9]*)
      printf '{"ok":false,"error":"lower limit must be an integer"}\n'
      exit 2
      ;;
  esac
  if [ "$start" -gt 100 ] || [ "$start" -ge "$end" ]; then
    printf '{"ok":false,"error":"lower limit must be below the upper limit"}\n'
    exit 2
  fi
  mkdir -p "$(state_dir)"
  printf '%s %s\n' "$end" "$start" > "$(state_dir)/limit"
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

[ $# -ge 1 ] || usage

case $1 in
  get) shift; cmd_get "$@" ;;
  set) shift; cmd_set "$@" ;;
  save-state) shift; cmd_save_state "$@" ;;
  boot-pref) shift; cmd_boot_pref "$@" ;;
  version) shift; cmd_version "$@" ;;
  *) usage ;;
esac
