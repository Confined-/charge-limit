#!/bin/bash
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/battery-charge-limit"
HELPER_BIN="/usr/local/bin/battery-charge-limit"

[ -x "$HELPER_BIN" ] || exit 0
[ -f "$STATE_DIR/apply-at-boot" ] || exit 0
[ -f "$STATE_DIR/limit" ] || exit 0

VALUES="$(tr -s '[:space:]' ' ' < "$STATE_DIR/limit")"
END="${VALUES%% *}"
REST="${VALUES#* }"
START="${REST%% *}"

case $END in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$END" -ge 20 ] && [ "$END" -le 100 ] || exit 0
case $START in
  ''|*[!0-9]*) START=0 ;;
esac
[ "$START" -lt "$END" ] || START=$((END > 5 ? END - 5 : 0))

exec sudo -n "$HELPER_BIN" set "$END" "$START" >/dev/null 2>&1
