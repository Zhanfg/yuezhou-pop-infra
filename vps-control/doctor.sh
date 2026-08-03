#!/usr/bin/env bash
set -Eeuo pipefail

CONTROL_USER="${CONTROL_USER:-ci-bootstrap}"
RUNNER_DIR="${RUNNER_DIR:-/srv/github-runner}"
FAILURES=0
WARNINGS=0

pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "command available: $1"
  else
    fail "command missing: $1"
  fi
}

printf 'VPS control-plane diagnostics\n'
printf 'Timestamp: %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

for cmd in bash curl git sshd systemctl; do
  check_command "$cmd"
done

if [[ ${EUID} -eq 0 ]]; then
  sshd -t && pass "sshd configuration is valid" || fail "sshd configuration is invalid"
else
  warn "run as root to validate sshd configuration"
fi

if id "$CONTROL_USER" >/dev/null 2>&1; then
  pass "control account exists: $CONTROL_USER"
  HOME_DIR="$(getent passwd "$CONTROL_USER" | awk -F: '{print $6}')"
  AUTHORIZED_KEYS="$HOME_DIR/.ssh/authorized_keys"
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    MODE="$(stat -c '%a' "$AUTHORIZED_KEYS")"
    [[ "$MODE" == "600" ]] && pass "authorized_keys mode is 600" || fail "authorized_keys mode is $MODE, expected 600"
    KEY_COUNT="$(grep -Ec '^ssh-(ed25519|rsa) ' "$AUTHORIZED_KEYS" || true)"
    (( KEY_COUNT > 0 )) && pass "authorized_keys contains $KEY_COUNT key(s)" || fail "authorized_keys contains no supported key"
  else
    fail "authorized_keys is missing for $CONTROL_USER"
  fi
else
  warn "control account does not exist: $CONTROL_USER"
fi

if [[ -f "$RUNNER_DIR/.runner" ]]; then
  pass "GitHub runner registration exists in $RUNNER_DIR"
  SERVICE_NAME="$(systemctl list-unit-files --type=service --no-legend | awk '/^actions\.runner\./ {print $1; exit}')"
  if [[ -n "$SERVICE_NAME" ]]; then
    systemctl is-active --quiet "$SERVICE_NAME" && pass "runner service active: $SERVICE_NAME" || fail "runner service inactive: $SERVICE_NAME"
  else
    fail "runner registration exists but no actions.runner systemd service was found"
  fi
else
  warn "GitHub runner is not installed in $RUNNER_DIR"
fi

ROOT_FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
if (( ROOT_FREE_KB >= 5 * 1024 * 1024 )); then
  pass "root filesystem has at least 5 GiB free"
else
  warn "root filesystem has less than 5 GiB free"
fi

MEM_TOTAL_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
SWAP_TOTAL_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
if (( MEM_TOTAL_KB + SWAP_TOTAL_KB >= 3 * 1024 * 1024 )); then
  pass "RAM plus swap is at least 3 GiB"
else
  warn "RAM plus swap is below 3 GiB; Node/Astro builds may be killed by OOM"
fi

for endpoint in \
  https://github.com \
  https://api.github.com \
  https://registry.npmjs.org \
  https://api.cloudflare.com/client/v4; do
  if curl -fsSIL --max-time 12 "$endpoint" >/dev/null 2>&1; then
    pass "network reachable: $endpoint"
  else
    fail "network unreachable: $endpoint"
  fi
done

printf '\nSummary: %d failure(s), %d warning(s)\n' "$FAILURES" "$WARNINGS"
(( FAILURES == 0 ))
