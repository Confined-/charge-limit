#!/bin/bash
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/battery-charge-limit"
HELPER_BIN="${CHARGE_LIMIT_HELPER_BIN:-/usr/local/bin/battery-charge-limit}"

[ -x "$HELPER_BIN" ] || exit 0
[ -f "$STATE_DIR/apply-at-boot" ] || exit 0
[ -f "$STATE_DIR/limit" ] || exit 0

STATE="$(tr -d '[:space:]' < "$STATE_DIR/limit")"

case $STATE in
  on) exec sudo -n "$HELPER_BIN" set 80 70 >/dev/null 2>&1 ;;
  off) exec sudo -n "$HELPER_BIN" set 100 0 >/dev/null 2>&1 ;;
  *) exit 0 ;;
esac
