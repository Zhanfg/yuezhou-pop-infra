#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CONTROL_USER="ci-bootstrap"
KEY_COMMENT="chatgpt-vps-ci-2026-08-03"
LOCK_ACCOUNT=false
PURGE_USER=false

log() { printf '[vps-control] %s\n' "$*"; }
die() { printf '[vps-control] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-control/revoke-ssh-access.sh [options]

Options:
  --user <name>          Account to modify. Default: ci-bootstrap
  --key-comment <text>   Remove authorized_keys lines containing this text
  --lock-account         Lock the account after removing the key
  --purge-user           Remove the account and home directory (destructive)
  -h, --help             Show this help

The per-user sshd restriction remains installed when only one key is removed,
so any remaining keys stay under the same no-forwarding policy.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      CONTROL_USER="$2"
      shift 2
      ;;
    --key-comment)
      [[ $# -ge 2 ]] || die "--key-comment requires a value"
      KEY_COMMENT="$2"
      shift 2
      ;;
    --lock-account)
      LOCK_ACCOUNT=true
      shift
      ;;
    --purge-user)
      PURGE_USER=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run with sudo or as root."
[[ -n "$KEY_COMMENT" ]] || die "Key comment must not be empty."

if ! id "$CONTROL_USER" >/dev/null 2>&1; then
  log "Account does not exist: $CONTROL_USER"
  exit 0
fi

HOME_DIR="$(getent passwd "$CONTROL_USER" | awk -F: '{print $6}')"
AUTHORIZED_KEYS="$HOME_DIR/.ssh/authorized_keys"

if [[ -f "$AUTHORIZED_KEYS" ]]; then
  TMP_FILE="$(mktemp)"
  grep -Fv -- "$KEY_COMMENT" "$AUTHORIZED_KEYS" > "$TMP_FILE" || true
  install -m 600 -o "$CONTROL_USER" -g "$CONTROL_USER" "$TMP_FILE" "$AUTHORIZED_KEYS"
  rm -f "$TMP_FILE"
  log "Removed keys matching comment: $KEY_COMMENT"
fi

MATCH_FILE="/etc/ssh/sshd_config.d/90-${CONTROL_USER}-restricted.conf"

if [[ "$PURGE_USER" == true ]]; then
  rm -f "$MATCH_FILE"
  userdel --remove "$CONTROL_USER"
  log "Removed account, home directory, and per-user sshd policy: $CONTROL_USER"
elif [[ "$LOCK_ACCOUNT" == true ]]; then
  usermod --lock --shell /usr/sbin/nologin "$CONTROL_USER"
  log "Locked account: $CONTROL_USER"
else
  log "Retained restricted sshd policy for any remaining keys."
fi

sshd -t || die "sshd validation failed after revocation."
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
elif systemctl is-active --quiet sshd; then
  systemctl reload sshd
fi

log "Revocation completed."
