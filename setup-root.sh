#!/bin/bash
set -u

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit "${2:-1}"
}

handle_revoke() {
  local dest_helper="/usr/local/bin/battery-charge-limit"
  local sudoers_dest="/etc/sudoers.d/battery-charge-limit"
  rm -f "$dest_helper" || fail "failed to remove helper" 1
  rm -f "$sudoers_dest" || fail "failed to remove sudoers rule" 1
  printf '{"ok":true,"revoked":true}\n'
  exit 0
}

resolve_target_user() {
  local user=""
  if [ -n "${PKEXEC_UID:-}" ]; then
    user="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
  elif [ -n "${SUDO_USER:-}" ]; then
    user="$SUDO_USER"
  else
    fail "cannot determine invoking user (no PKEXEC_UID)" 2
  fi
  [ -n "$user" ] || fail "cannot resolve invoking user" 2
  case $user in
    ALL|Host_Alias|Cmnd_Alias|User_Alias|Runas_Alias)
      fail "reserved sudoers name: $user" 2
      ;;
  esac
  if ! [[ $user =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    fail "invalid username: $user" 2
  fi
  id -u "$user" >/dev/null 2>&1 || fail "no such user: $user" 2
  printf '%s' "$user"
}

install_helper() {
  local src=$1 dest=$2
  [ -f "$src" ] || fail "helper.sh not found next to setup-root.sh" 1
  install -o root -g root -m 0755 "$src" "$dest" || fail "failed to install helper binary" 1
}

install_sudoers() {
  local user=$1 dest_helper=$2 sudoers_dest=$3
  local tmp
  tmp="$(mktemp)" || fail "mktemp failed" 1
  printf '# Installed by the confined.charge-limit Omarchy plugin\n' > "$tmp"
  printf '# Grants passwordless access to exactly the two charge-limit commands below.\n' >> "$tmp"
  printf '%s ALL=(root) NOPASSWD: %s set 80 70, %s set 100 0\n' "$user" "$dest_helper" "$dest_helper" >> "$tmp" || fail "failed to write temp sudoers" 1
  chown root:root "$tmp" || fail "chown failed" 1
  chmod 0440 "$tmp" || fail "chmod failed" 1
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "sudoers validation failed" 1
  fi
  mv -f "$tmp" "$sudoers_dest" || fail "failed to activate sudoers rule" 1
}

main() {
  [ "$(id -u)" -eq 0 ] || fail "setup-root.sh must run as root (via pkexec)" 1
  if [ "${1:-}" = "--revoke" ]; then
    handle_revoke
  fi
  if [ $# -gt 1 ]; then
    fail "usage: setup-root.sh [--revoke]" 2
  fi
  local target
  target=$(resolve_target_user)
  local script_dir src_helper dest_helper sudoers_dest
  script_dir="$(cd "$(dirname "$0")" && pwd)" || fail "cannot resolve script directory"
  src_helper="$script_dir/helper.sh"
  dest_helper="/usr/local/bin/battery-charge-limit"
  sudoers_dest="/etc/sudoers.d/battery-charge-limit"
  install_helper "$src_helper" "$dest_helper"
  install_sudoers "$target" "$dest_helper" "$sudoers_dest"
  printf '{"ok":true}\n'
}

main "$@"
