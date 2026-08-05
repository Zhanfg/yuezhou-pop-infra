#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

NODE_MAJOR="${RUNNER_NODE_MAJOR:-22}"
RUNNER_DIR="${RUNNER_DIR:-/opt/github-actions-runner}"
RUNNER_USER="${RUNNER_USER:-github-runner}"
SERVICE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log(){ printf '\033[1;34m[repair]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo/root"
[[ $NODE_MAJOR =~ ^[0-9]+$ ]] || die "Invalid RUNNER_NODE_MAJOR"
[[ -f "$RUNNER_DIR/.service" ]] || die "Runner service marker not found: $RUNNER_DIR/.service"
id "$RUNNER_USER" >/dev/null 2>&1 || die "Runner user not found: $RUNNER_USER"

SERVICE_NAME=$(tr -d '\r\n' < "$RUNNER_DIR/.service")
[[ -n $SERVICE_NAME ]] || die "Runner service name is empty"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl jq git tar xz-utils python3

case "$(uname -m)" in
  x86_64|amd64) NODE_ARCH=x64 ;;
  aarch64|arm64) NODE_ARCH=arm64 ;;
  armv7l|armv6l) NODE_ARCH=armv7l ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

CURRENT=""
command -v node >/dev/null 2>&1 && CURRENT=$(node --version 2>/dev/null || true)
if [[ $CURRENT == v${NODE_MAJOR}.* ]] && command -v npm >/dev/null 2>&1; then
  log "Node.js already available: $CURRENT"
else
  VERSION=$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json \
    | jq -r --arg prefix "v${NODE_MAJOR}." '[.[] | select(.version | startswith($prefix))][0].version // empty')
  [[ -n $VERSION ]] || die "Unable to resolve Node.js v${NODE_MAJOR}.x"

  ASSET="node-${VERSION}-linux-${NODE_ARCH}.tar.xz"
  BASE="https://nodejs.org/dist/${VERSION}"
  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP:-}"' EXIT

  curl -fL --retry 3 -o "$TMP/$ASSET" "$BASE/$ASSET"
  curl -fL --retry 3 -o "$TMP/SHASUMS256.txt" "$BASE/SHASUMS256.txt"
  (cd "$TMP" && grep -F "  $ASSET" SHASUMS256.txt | sha256sum -c -)

  install -d -o root -g root -m 0755 /usr/local/lib/nodejs
  tar -xJf "$TMP/$ASSET" -C /usr/local/lib/nodejs
  PREFIX="/usr/local/lib/nodejs/node-${VERSION}-linux-${NODE_ARCH}"
  chmod 0755 /usr/local/lib/nodejs
  chmod -R a+rX "$PREFIX"
  for binary in node npm npx corepack; do
    [[ -x "$PREFIX/bin/$binary" ]] && ln -sfn "$PREFIX/bin/$binary" "/usr/local/bin/$binary"
  done
  [[ $(/usr/local/bin/node --version) == "$VERSION" ]] || die "Node.js verification failed"
  /usr/local/bin/npm --version >/dev/null
  log "Installed Node.js $VERSION"
fi

# Repair permissions from v1 installations where umask 077 made the Node tree root-only.
if [[ -L /usr/local/bin/node ]]; then
  NODE_TARGET=$(readlink -f /usr/local/bin/node)
  NODE_PREFIX=$(dirname "$(dirname "$NODE_TARGET")")
  [[ $NODE_PREFIX == /usr/local/lib/nodejs/* ]] || die "Unexpected Node.js target: $NODE_TARGET"
  chmod 0755 /usr/local/lib/nodejs
  chmod -R a+rX "$NODE_PREFIX"
fi

install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 700 "/home/$RUNNER_USER/.npm"
DROPIN="/etc/systemd/system/${SERVICE_NAME}.d"
mkdir -p "$DROPIN"
cat > "$DROPIN/toolchain.conf" <<EOF
[Service]
Environment="PATH=$SERVICE_PATH"
Environment="npm_config_cache=/home/$RUNNER_USER/.npm"
EOF
chmod 0644 "$DROPIN/toolchain.conf"

systemctl daemon-reload
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl is-active --quiet "$SERVICE_NAME" || die "Runner service failed after restart"

for command_name in git node npm python3 curl; do
  runuser -u "$RUNNER_USER" -- env HOME="/home/$RUNNER_USER" PATH="$SERVICE_PATH" \
    bash -c "command -v $command_name >/dev/null" || die "$command_name is unavailable to $RUNNER_USER"
done

runuser -u "$RUNNER_USER" -- env HOME="/home/$RUNNER_USER" PATH="$SERVICE_PATH" node --version
runuser -u "$RUNNER_USER" -- env HOME="/home/$RUNNER_USER" PATH="$SERVICE_PATH" npm --version
runuser -u "$RUNNER_USER" -- env HOME="/home/$RUNNER_USER" PATH="$SERVICE_PATH" python3 --version
log "Runner toolchain repair passed: $SERVICE_NAME"
