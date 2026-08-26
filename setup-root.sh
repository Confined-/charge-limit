#!/bin/bash
set -u

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit "${2:-1}"
}

[ "$(id -u)" -eq 0 ] || fail "setup-root.sh must run as root (via pkexec)" 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || fail "cannot resolve script directory"
SRC_HELPER="$SCRIPT_DIR/helper.sh"
DEST_HELPER="/usr/local/bin/battery-charge-limit"
SUDOERS_DEST="/etc/sudoers.d/battery-charge-limit"

if [ "${1:-}" = "--revoke" ]; then
  rm -f "$DEST_HELPER" || fail "failed to remove helper" 1
  rm -f "$SUDOERS_DEST" || fail "failed to remove sudoers rule" 1
  printf '{"ok":true,"revoked":true}\n'
  exit 0
fi

if [ $# -gt 1 ]; then
  fail "usage: setup-root.sh [--revoke]" 2
fi
# Backward-compat: older widget versions passed a username; new widget passes
# nothing and we derive the user from PKEXEC_UID. Accept either.

if [ -n "${PKEXEC_UID:-}" ]; then
  TARGET_USER="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
elif [ -n "${SUDO_USER:-}" ]; then
  TARGET_USER="$SUDO_USER"
else
  fail "cannot determine invoking user (no PKEXEC_UID)" 2
fi

[ -n "$TARGET_USER" ] || fail "cannot resolve invoking user" 2
if ! [[ $TARGET_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
  fail "invalid username: $TARGET_USER" 2
fi
case $TARGET_USER in
  ALL|Host_Alias|Cmnd_Alias|User_Alias|Runas_Alias)
    fail "reserved sudoers name: $TARGET_USER" 2
    ;;
esac
id -u "$TARGET_USER" >/dev/null 2>&1 || fail "no such user: $TARGET_USER" 2

[ -f "$SRC_HELPER" ] || fail "helper.sh not found next to setup-root.sh" 1

install -o root -g root -m 0755 "$SRC_HELPER" "$DEST_HELPER" || fail "failed to install helper binary" 1

TMP_SUDOERS="$(mktemp)" || fail "mktemp failed" 1
printf '# Installed by the confined.charge-limit Omarchy plugin\n' > "$TMP_SUDOERS"
printf '# Grants passwordless access to exactly the two charge-limit commands below.\n' >> "$TMP_SUDOERS"
printf '%s ALL=(root) NOPASSWD: %s set 80 70, %s set 100 0\n' "$TARGET_USER" "$DEST_HELPER" "$DEST_HELPER" >> "$TMP_SUDOERS" || fail "failed to write temp sudoers" 1
chown root:root "$TMP_SUDOERS" || fail "chown failed" 1
chmod 0440 "$TMP_SUDOERS" || fail "chmod failed" 1

if ! visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
  rm -f "$TMP_SUDOERS"
  fail "sudoers validation failed" 1
fi

mv -f "$TMP_SUDOERS" "$SUDOERS_DEST" || fail "failed to activate sudoers rule" 1

printf '{"ok":true}\n'
exit 0
