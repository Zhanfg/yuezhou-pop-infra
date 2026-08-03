#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_KEY_FILE="${ROOT_DIR}/keys/chatgpt-vps-ci-2026-08-03.pub"
CONTROL_USER="ci-bootstrap"
KEY_FILE="$DEFAULT_KEY_FILE"
LOCK_PASSWORD=true

log() { printf '[vps-control] %s\n' "$*"; }
warn() { printf '[vps-control] WARNING: %s\n' "$*" >&2; }
die() { printf '[vps-control] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-control/bootstrap-ssh-access.sh [options]

Options:
  --user <name>       Dedicated SSH account. Default: ci-bootstrap
  --key-file <path>   Public key file. Default: bundled temporary public key
  --no-lock-password  Do not lock the account password after creation
  -h, --help          Show this help

The script creates a dedicated non-root account, installs one public key,
and applies an sshd Match block that disables password authentication and
all forwarding. It intentionally grants no sudo privileges.
USAGE
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run with sudo or as root."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      CONTROL_USER="$2"
      shift 2
      ;;
    --key-file)
      [[ $# -ge 2 ]] || die "--key-file requires a value"
      KEY_FILE="$2"
      shift 2
      ;;
    --no-lock-password)
      LOCK_PASSWORD=false
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

require_root
require_command sshd
require_command install
require_command getent
require_command awk
valid_username "$CONTROL_USER" || die "Invalid username: $CONTROL_USER"
[[ -f "$KEY_FILE" ]] || die "Public key file not found: $KEY_FILE"

PUBLIC_KEY="$(awk 'NF && $1 ~ /^ssh-(ed25519|rsa)$/ { print; exit }' "$KEY_FILE")"
[[ -n "$PUBLIC_KEY" ]] || die "No supported SSH public key found in $KEY_FILE"

if ! id "$CONTROL_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$CONTROL_USER"
  log "Created account: $CONTROL_USER"
fi

HOME_DIR="$(getent passwd "$CONTROL_USER" | awk -F: '{print $6}')"
[[ -n "$HOME_DIR" ]] || die "Could not resolve home directory for $CONTROL_USER"

install -d -m 700 -o "$CONTROL_USER" -g "$CONTROL_USER" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
chown "$CONTROL_USER:$CONTROL_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"

KEY_COMMENT="${PUBLIC_KEY##* }"
if ! grep -Fqx "$PUBLIC_KEY" "$HOME_DIR/.ssh/authorized_keys"; then
  printf '%s\n' "$PUBLIC_KEY" >> "$HOME_DIR/.ssh/authorized_keys"
  log "Installed public key: $KEY_COMMENT"
else
  log "Public key already installed: $KEY_COMMENT"
fi

if [[ "$LOCK_PASSWORD" == true ]]; then
  passwd -l "$CONTROL_USER" >/dev/null 2>&1 || true
fi

MATCH_FILE="/etc/ssh/sshd_config.d/90-${CONTROL_USER}-restricted.conf"
install -d -m 755 /etc/ssh/sshd_config.d
cat > "$MATCH_FILE" <<EOF
# Managed by yuezhou-pop-infra/vps-control/bootstrap-ssh-access.sh
Match User ${CONTROL_USER}
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    PermitTTY yes
    X11Forwarding no
    AllowAgentForwarding no
    AllowTcpForwarding no
    PermitTunnel no
    GatewayPorts no
EOF
chmod 644 "$MATCH_FILE"

if ! sshd -t; then
  rm -f "$MATCH_FILE"
  die "sshd validation failed; removed $MATCH_FILE"
fi

if systemctl is-active --quiet ssh; then
  systemctl reload ssh
elif systemctl is-active --quiet sshd; then
  systemctl reload sshd
else
  warn "Neither ssh.service nor sshd.service is active; configuration was written but not reloaded."
fi

log "SSH access is ready for user: $CONTROL_USER"
log "No sudo permission was granted."
log "Revoke with: sudo bash vps-control/revoke-ssh-access.sh --user $CONTROL_USER --key-comment $KEY_COMMENT"
