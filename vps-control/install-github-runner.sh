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
  --replace                   Replace an existing registration in the target directory
  --keep-token-file           Do not delete the one-time token file after registration
  --allow-unverified-download Continue if GitHub's release API exposes no SHA-256 digest
  -h, --help                  Show this help

The token is read from a root-only file, never passed as a command-line argument
to this script, and is deleted by default after successful registration.
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

TOKEN_MODE="$(stat -c '%a' "$TOKEN_FILE")"
if (( 10#$TOKEN_MODE > 600 )); then
  die "Token file must not be more permissive than mode 600: $TOKEN_FILE"
fi

install_dependencies
require_command runuser
require_command systemctl

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

install -d -m 750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"

if [[ -f "$RUNNER_DIR/.runner" ]]; then
  if [[ "$REPLACE_EXISTING" != true ]]; then
    die "Runner already configured in $RUNNER_DIR. Use --replace after checking its current service."
  fi
  if [[ -x "$RUNNER_DIR/svc.sh" ]]; then
    "$RUNNER_DIR/svc.sh" stop || true
    "$RUNNER_DIR/svc.sh" uninstall || true
  fi
  rm -rf "$RUNNER_DIR"/* "$RUNNER_DIR"/.[!.]* "$RUNNER_DIR"/..?* 2>/dev/null || true
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
  --replace
)

runuser -u "$RUNNER_USER" -- bash -lc \
  "cd '$RUNNER_DIR' && ./config.sh ${CONFIG_ARGS[*]@Q}"
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

SERVICE_NAME="$(systemctl list-unit-files --type=service --no-legend | awk '/^actions\.runner\./ {print $1; exit}')"
[[ -n "$SERVICE_NAME" ]] || die "Runner service was installed but its systemd unit could not be resolved."
systemctl is-active --quiet "$SERVICE_NAME" || die "Runner service is not active: $SERVICE_NAME"

log "Runner installed successfully."
log "Service: $SERVICE_NAME"
log "Directory: $RUNNER_DIR"
log "Labels: self-hosted, Linux, ${RUNNER_ARCH}, $RUNNER_LABELS"
