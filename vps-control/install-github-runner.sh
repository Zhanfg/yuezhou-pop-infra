#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RUNNER_URL=""
TOKEN_FILE=""
RUNNER_USER="github-runner"
RUNNER_NAME="$(hostname -s)-runner"
RUNNER_LABELS="vps,ci"
RUNNER_DIR="/srv/github-runner"
RUNNER_VERSION="latest"
ALLOW_UNVERIFIED=false
ALLOW_PRIVILEGED_USER=false
CONSUME_TOKEN=true
REPLACE_EXISTING=false

log() { printf '[runner-install] %s\n' "$*"; }
warn() { printf '[runner-install] WARNING: %s\n' "$*" >&2; }
die() { printf '[runner-install] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-control/install-github-runner.sh \
    --url https://github.com/OWNER/REPOSITORY \
    --token-file /root/github-runner-registration-token

Options:
  --url <url>                 GitHub repository or organization URL
  --token-file <path>         File containing a one-time runner registration token
  --user <name>               Service account. Default: github-runner
  --name <name>               Runner name. Default: <hostname>-runner
  --labels <csv>              Custom labels. Default: vps,ci
  --dir <path>                Installation directory. Default: /srv/github-runner
  --version <version>         Runner version without v, or latest
  --replace                   Replace an existing local registration
  --keep-token-file           Do not delete the one-time token file after registration
  --allow-unverified-download Continue if GitHub's release API exposes no SHA-256 digest
  --allow-privileged-user     Permit an existing account in sudo/docker-equivalent groups
  -h, --help                  Show this help

The registration token is read from a root-only file instead of shell history
or this installer's arguments. GitHub's config.sh still receives the required
short-lived token during registration. The token file is deleted by default.

For a persistent VPS, use separate low-privilege users and directories for CI
validation and production deployment. Never place either runner user in sudo,
docker, lxd, libvirt, wheel, or admin groups unless the risk is explicitly
accepted with --allow-privileged-user.
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

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl jq tar gzip git libicu-dev
  else
    die "Only Debian/Ubuntu apt-based hosts are currently supported."
  fi
}

assert_runner_user_is_unprivileged() {
  local groups privileged_group
  groups="$(id -nG "$RUNNER_USER")"
  for privileged_group in sudo admin wheel docker lxd libvirt; do
    if grep -Eq "(^|[[:space:]])${privileged_group}([[:space:]]|$)" <<<"$groups"; then
      if [[ "$ALLOW_PRIVILEGED_USER" == true ]]; then
        warn "Runner account $RUNNER_USER belongs to privileged group: $privileged_group"
      else
        die "Runner account $RUNNER_USER belongs to privileged group $privileged_group. Use a dedicated account or explicitly pass --allow-privileged-user."
      fi
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || die "--url requires a value"
      RUNNER_URL="$2"
      shift 2
      ;;
    --token-file)
      [[ $# -ge 2 ]] || die "--token-file requires a value"
      TOKEN_FILE="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      RUNNER_USER="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      RUNNER_NAME="$2"
      shift 2
      ;;
    --labels)
      [[ $# -ge 2 ]] || die "--labels requires a value"
      RUNNER_LABELS="$2"
      shift 2
      ;;
    --dir)
      [[ $# -ge 2 ]] || die "--dir requires a value"
      RUNNER_DIR="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      RUNNER_VERSION="${2#v}"
      shift 2
      ;;
    --replace)
      REPLACE_EXISTING=true
      shift
      ;;
    --keep-token-file)
      CONSUME_TOKEN=false
      shift
      ;;
    --allow-unverified-download)
      ALLOW_UNVERIFIED=true
      shift
      ;;
    --allow-privileged-user)
      ALLOW_PRIVILEGED_USER=true
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
[[ "$RUNNER_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?/?$ ]] || \
  die "--url must be a GitHub repository or organization URL."
[[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" ]] || die "Token file not found: $TOKEN_FILE"
valid_username "$RUNNER_USER" || die "Invalid runner username: $RUNNER_USER"
[[ "$RUNNER_LABELS" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || die "Invalid labels: $RUNNER_LABELS"
[[ "$RUNNER_NAME" != *$'\n'* && -n "$RUNNER_NAME" ]] || die "Invalid runner name."

TOKEN_MODE="$(stat -c '%a' "$TOKEN_FILE")"
case "$TOKEN_MODE" in
  400|600) ;;
  *) die "Token file mode must be 400 or 600, got $TOKEN_MODE: $TOKEN_FILE" ;;
esac

install_dependencies
require_command runuser
require_command systemctl
require_command sha256sum

case "$(uname -m)" in
  x86_64|amd64) RUNNER_ARCH="x64" ;;
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

RELEASE_JSON="$(mktemp)"
ARCHIVE="$(mktemp --suffix=.tar.gz)"
cleanup() {
  rm -f "$RELEASE_JSON" "$ARCHIVE"
}
trap cleanup EXIT

if [[ "$RUNNER_VERSION" == "latest" ]]; then
  curl -fsSL --retry 3 --retry-delay 2 \
    https://api.github.com/repos/actions/runner/releases/latest \
    -o "$RELEASE_JSON"
  RUNNER_VERSION="$(jq -er '.tag_name | ltrimstr("v")' "$RELEASE_JSON")"
else
  curl -fsSL --retry 3 --retry-delay 2 \
    "https://api.github.com/repos/actions/runner/releases/tags/v${RUNNER_VERSION}" \
    -o "$RELEASE_JSON"
fi

ASSET_NAME="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
ASSET_URL="$(jq -er --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .browser_download_url' "$RELEASE_JSON")"
ASSET_DIGEST="$(jq -r --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .digest // empty' "$RELEASE_JSON")"

log "Downloading GitHub Actions Runner v${RUNNER_VERSION} (${RUNNER_ARCH})"
curl -fL --retry 3 --retry-delay 2 "$ASSET_URL" -o "$ARCHIVE"

if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  printf '%s  %s\n' "${ASSET_DIGEST#sha256:}" "$ARCHIVE" | sha256sum -c - >/dev/null
  log "Verified release SHA-256 digest."
elif [[ "$ALLOW_UNVERIFIED" == true ]]; then
  warn "GitHub release metadata exposed no SHA-256 digest; continuing by explicit request."
else
  die "GitHub release metadata exposed no SHA-256 digest. Re-run with --allow-unverified-download only after manual verification."
fi

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
fi
assert_runner_user_is_unprivileged

install -d -m 750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"

if [[ -f "$RUNNER_DIR/.runner" ]]; then
  if [[ "$REPLACE_EXISTING" != true ]]; then
    die "Runner already configured in $RUNNER_DIR. Use --replace after checking its current service."
  fi
  if [[ -x "$RUNNER_DIR/svc.sh" ]]; then
    "$RUNNER_DIR/svc.sh" stop || true
    "$RUNNER_DIR/svc.sh" uninstall || true
  fi
  find "$RUNNER_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi

tar -xzf "$ARCHIVE" -C "$RUNNER_DIR"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

if [[ -x "$RUNNER_DIR/bin/installdependencies.sh" ]]; then
  "$RUNNER_DIR/bin/installdependencies.sh"
fi

REGISTRATION_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
[[ -n "$REGISTRATION_TOKEN" ]] || die "Token file is empty."

CONFIG_ARGS=(
  --unattended
  --url "$RUNNER_URL"
  --token "$REGISTRATION_TOKEN"
  --name "$RUNNER_NAME"
  --labels "$RUNNER_LABELS"
  --work _work
)
if [[ "$REPLACE_EXISTING" == true ]]; then
  CONFIG_ARGS+=(--replace)
fi

runuser -u "$RUNNER_USER" -- \
  bash -c 'cd "$1"; shift; exec ./config.sh "$@"' \
  _ "$RUNNER_DIR" "${CONFIG_ARGS[@]}"
unset REGISTRATION_TOKEN

"$RUNNER_DIR/svc.sh" install "$RUNNER_USER"
"$RUNNER_DIR/svc.sh" start

install -d -m 755 /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/actions_runner_services.conf <<'EOF'
$nrconf{override_rc}{qr(^actions\.runner\..+\.service$)} = 0;
EOF
chmod 644 /etc/needrestart/conf.d/actions_runner_services.conf

if [[ "$CONSUME_TOKEN" == true ]]; then
  if command -v shred >/dev/null 2>&1; then
    shred -u "$TOKEN_FILE"
  else
    rm -f "$TOKEN_FILE"
  fi
fi

if ! "$RUNNER_DIR/svc.sh" status; then
  die "Runner service was installed but is not active."
fi

SERVICE_NAME="unknown"
if [[ -f "$RUNNER_DIR/.service" ]]; then
  SERVICE_NAME="$(tr -d '\r\n' < "$RUNNER_DIR/.service")"
fi

log "Runner installed successfully."
log "Service: $SERVICE_NAME"
log "User: $RUNNER_USER"
log "Directory: $RUNNER_DIR"
log "Labels: self-hosted, Linux, ${RUNNER_ARCH}, $RUNNER_LABELS"
