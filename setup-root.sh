#!/bin/bash
set -u

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit "${2:-1}"
}

[ "$(id -u)" -eq 0 ] || fail "setup-root.sh must run as root (via pkexec)" 1
[ $# -eq 1 ] || fail "usage: setup-root.sh <username>" 2

TARGET_USER=$1
id -u "$TARGET_USER" >/dev/null 2>&1 || fail "no such user: $TARGET_USER" 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || fail "cannot resolve script directory"
SRC_HELPER="$SCRIPT_DIR/helper.sh"
DEST_HELPER="/usr/local/bin/battery-charge-limit"
SUDOERS_DEST="/etc/sudoers.d/battery-charge-limit"

[ -f "$SRC_HELPER" ] || fail "helper.sh not found next to setup-root.sh" 1

install -o root -g root -m 0755 "$SRC_HELPER" "$DEST_HELPER" || fail "failed to install helper binary" 1

TMP_SUDOERS="$(mktemp)" || fail "mktemp failed" 1
printf '# Installed by the confined.charge-limit Omarchy plugin\n' > "$TMP_SUDOERS"
printf '# Grants passwordless access to the battery charge limit helper only.\n' >> "$TMP_SUDOERS"
printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$DEST_HELPER" >> "$TMP_SUDOERS" || fail "failed to write temp sudoers" 1
chown root:root "$TMP_SUDOERS" || fail "chown failed" 1
chmod 0440 "$TMP_SUDOERS" || fail "chmod failed" 1

if ! visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
  rm -f "$TMP_SUDOERS"
  fail "sudoers validation failed" 1
fi

mv -f "$TMP_SUDOERS" "$SUDOERS_DEST" || fail "failed to activate sudoers rule" 1

printf '{"ok":true}\n'
exit 0
