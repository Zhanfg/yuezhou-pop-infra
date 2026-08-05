#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
CMD="${1:-install}"
[[ $# -gt 0 ]] && shift || true
ORG="${RUNNER_ORG:-}"
NAME="${RUNNER_NAME:-$(hostname -s)-actions}"
LABELS="${RUNNER_LABELS:-light-ci}"
USER_NAME="${RUNNER_USER:-github-runner}"
INSTALL_DIR="${RUNNER_DIR:-/opt/github-actions-runner}"
WORK_DIR="${RUNNER_WORK_DIR:-_work}"
MEM_HIGH="${RUNNER_MEMORY_HIGH:-1100M}"
MEM_MAX="${RUNNER_MEMORY_MAX:-1400M}"
CPU_QUOTA="${RUNNER_CPU_QUOTA:-150%}"
SWAP_SIZE="${RUNNER_SWAP_SIZE:-2G}"
TOKEN="${RUNNER_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
REPLACE=0 YES=0 NO_SWAP=0 PURGE=0 LOCAL_ONLY=0 DRY_RUN=0
API_VERSION="2022-11-28"

log(){ printf '\033[1;34m[runner]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
run(){ if ((DRY_RUN)); then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
write_file(){ local p=$1; if ((DRY_RUN)); then cat >/dev/null; printf '[dry-run] write %q\n' "$p"; else cat >"$p"; fi; }

usage(){ cat <<'USAGE'
Usage:
  sudo bash runner.sh install --org ORG [options]
  sudo bash runner.sh status|doctor|logs|restart [--dir PATH]
  sudo bash runner.sh uninstall [--org ORG] [--local-only] [--purge]

Options:
  --org NAME              GitHub organization (required for install)
  --name NAME             Runner name (default: <hostname>-actions)
  --labels CSV            Custom labels (default: light-ci)
  --user NAME             Local service user (default: github-runner)
  --dir PATH              Install directory (default: /opt/github-actions-runner)
  --memory-high SIZE      systemd MemoryHigh (default: 1100M)
  --memory-max SIZE       systemd MemoryMax (default: 1400M)
  --cpu-quota PERCENT     systemd CPUQuota (default: 150%)
  --swap-size SIZE        Create swap on low-memory hosts (default: 2G)
  --no-swap               Do not create swap
  --token TOKEN           PAT, registration token, or removal token
  --replace               Replace an existing local runner
  --yes                   Skip confirmations
  --dry-run               Print the installation plan only
  --local-only            Uninstall local service without GitHub removal
  --purge                 Delete runner files and local user
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG=${2:?}; shift 2;; --name) NAME=${2:?}; shift 2;;
    --labels) LABELS=${2:?}; shift 2;; --user) USER_NAME=${2:?}; shift 2;;
    --dir) INSTALL_DIR=${2:?}; shift 2;; --memory-high) MEM_HIGH=${2:?}; shift 2;;
    --memory-max) MEM_MAX=${2:?}; shift 2;; --cpu-quota) CPU_QUOTA=${2:?}; shift 2;;
    --swap-size) SWAP_SIZE=${2:?}; shift 2;; --token) TOKEN=${2:?}; shift 2;;
    --replace) REPLACE=1; shift;; --yes) YES=1; shift;; --no-swap) NO_SWAP=1; shift;;
    --purge) PURGE=1; shift;; --local-only) LOCAL_ONLY=1; shift;; --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;; --version) echo "$VERSION"; exit 0;; *) die "Unknown option: $1";;
  esac
done

[[ $INSTALL_DIR == /* && $INSTALL_DIR != / && $INSTALL_DIR != /opt && $INSTALL_DIR != /usr && $INSTALL_DIR != /home ]] || die "Unsafe --dir: $INSTALL_DIR"
[[ $LABELS =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] || die "Invalid labels"
NAME=${NAME//[^A-Za-z0-9._-]/-}; NAME=${NAME:0:64}

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo/root"; }
confirm(){ ((YES)) && return 0; [[ -t 0 ]] || die "Use --yes for non-interactive mode"; read -r -p "$1 [y/N] " a; [[ $a =~ ^[Yy]$ ]]; }
service_name(){ [[ -f "$INSTALL_DIR/.service" ]] && tr -d '\r\n' <"$INSTALL_DIR/.service" || true; }
runner_field(){ [[ -f "$INSTALL_DIR/.runner" ]] && jq -r ".${1} // empty" "$INSTALL_DIR/.runner" 2>/dev/null || true; }
arch(){ case "$(uname -m)" in x86_64|amd64) echo x64;; aarch64|arm64) echo arm64;; armv7l|armv6l) echo arm;; *) die "Unsupported arch";; esac; }

prompt_token(){ [[ -n $TOKEN ]] && return; [[ -t 0 ]] || die "Token required"; read -r -s -p "GitHub PAT or temporary runner token: " TOKEN; echo >&2; [[ -n $TOKEN ]] || die "Empty token"; }
api_token(){
  local endpoint=$1 tmp code out
  prompt_token; tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "https://api.github.com/orgs/$ORG/actions/runners/$endpoint" || true)
  if [[ $code == 201 ]]; then out=$(jq -r '.token' "$tmp"); rm -f "$tmp"; printf '%s\n' "$out"; return; fi
  rm -f "$tmp"; printf '%s\n' "$TOKEN"
}

packages(){ run env DEBIAN_FRONTEND=noninteractive apt-get update; run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq git tar gzip coreutils util-linux procps; }
user_setup(){
  id "$USER_NAME" >/dev/null 2>&1 || run useradd --system --create-home --home-dir "/home/$USER_NAME" --shell /bin/bash "$USER_NAME"
  getent group sudo >/dev/null && run gpasswd -d "$USER_NAME" sudo >/dev/null 2>&1 || true
  getent group docker >/dev/null && run gpasswd -d "$USER_NAME" docker >/dev/null 2>&1 || true
}

swap_setup(){
  ((NO_SWAP)) && return; local mem swap f=/swapfile-github-runner
  mem=$(awk '/MemTotal:/{print $2}' /proc/meminfo); swap=$(awk '/SwapTotal:/{print $2}' /proc/meminfo)
  ((mem>=3145728 || swap>=1048576)) && return
  log "Creating $SWAP_SIZE swap"
  [[ -f $f ]] || { run fallocate -l "$SWAP_SIZE" "$f"; run chmod 600 "$f"; run mkswap "$f"; }
  swapon --show=NAME --noheadings | grep -Fxq "$f" || run swapon "$f"
  grep -Fq "$f none swap sw 0 0" /etc/fstab || { ((DRY_RUN)) && echo "[dry-run] append fstab" || echo "$f none swap sw 0 0" >>/etc/fstab; }
  write_file /etc/sysctl.d/90-github-runner.conf <<'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
  run sysctl --system >/dev/null
}

download_runner(){
  local a rel v asset url digest tmp
  a=$(arch)
  if ((DRY_RUN)); then log "Would download latest official actions/runner package for $a"; run mkdir -p "$INSTALL_DIR"; return; fi
  rel=$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' -H "X-GitHub-Api-Version: $API_VERSION" https://api.github.com/repos/actions/runner/releases/latest)
  v=$(jq -r '.tag_name' <<<"$rel"); v=${v#v}; asset="actions-runner-linux-$a-$v.tar.gz"
  url=$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.browser_download_url' <<<"$rel")
  digest=$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.digest // empty' <<<"$rel")
  [[ -n $url && $digest == sha256:* ]] || die "Missing runner asset or SHA-256 digest"
  tmp=$(mktemp -d); curl -fL --retry 3 -o "$tmp/$asset" "$url"
  echo "${digest#sha256:}  $tmp/$asset" | sha256sum -c -
  run mkdir -p "$INSTALL_DIR"; tar -xzf "$tmp/$asset" -C "$INSTALL_DIR"; rm -rf "$tmp"
  chown -R "$USER_NAME:$USER_NAME" "$INSTALL_DIR"; chmod 750 "$INSTALL_DIR"
  if [[ -x "$INSTALL_DIR/bin/installdependencies.sh" ]]; then "$INSTALL_DIR/bin/installdependencies.sh"; fi
}

limits(){
  local svc=$1 d="/etc/systemd/system/$svc.d"
  run mkdir -p "$d"
  write_file "$d/limits.conf" <<EOF_LIMITS
[Service]
MemoryHigh=$MEM_HIGH
MemoryMax=$MEM_MAX
CPUQuota=$CPU_QUOTA
TasksMax=512
Nice=5
OOMScoreAdjust=500
Restart=always
RestartSec=10s
EOF_LIMITS
  run systemctl daemon-reload
}

install_cmd(){
  need_root; [[ -n $ORG ]] || die "--org is required"; packages; user_setup; swap_setup
  if [[ -f "$INSTALL_DIR/.runner" ]]; then
    local old_url old_name svc backup
    old_url=$(runner_field gitHubUrl); old_name=$(runner_field agentName)
    if [[ $old_url == "https://github.com/$ORG" && $old_name == "$NAME" && $REPLACE -eq 0 ]]; then log "Runner already configured"; return; fi
    warn "Existing runner: ${old_name:-unknown} @ ${old_url:-unknown}"
    ((REPLACE)) || confirm "Replace local runner?" || die "Cancelled"
    svc=$(service_name); [[ -n $svc ]] && run systemctl stop "$svc" || true
    [[ -x "$INSTALL_DIR/svc.sh" ]] && (cd "$INSTALL_DIR" && run ./svc.sh uninstall) || true
    backup="$INSTALL_DIR.backup.$(date +%Y%m%d-%H%M%S)"; run mv "$INSTALL_DIR" "$backup"
  fi
  download_runner
  local reg args svc
  if ((DRY_RUN)); then reg=DRY_RUN; else reg=$(api_token registration-token); fi
  args=(--unattended --url "https://github.com/$ORG" --token "$reg" --name "$NAME" --work "$WORK_DIR" --labels "$LABELS" --replace)
  if ((DRY_RUN)); then log "Would register $NAME to $ORG"; else runuser -u "$USER_NAME" -- env HOME="/home/$USER_NAME" "$INSTALL_DIR/config.sh" "${args[@]}"; fi
  if ((DRY_RUN)); then svc="actions.runner.$ORG.$NAME.service"; else (cd "$INSTALL_DIR" && ./svc.sh install "$USER_NAME"); svc=$(service_name); fi
  limits "$svc"; run systemctl enable "$svc"; run systemctl restart "$svc"
  log "Installed: $NAME"; echo "runs-on: [self-hosted, linux, $(arch), ${LABELS//,/, }]"
}

status_cmd(){ need_root; local s; s=$(service_name); [[ -n $s ]] || die "Runner service not found"; systemctl --no-pager --full status "$s" || true; }
logs_cmd(){ need_root; local s; s=$(service_name); [[ -n $s ]] || die "Runner service not found"; journalctl -u "$s" -n 120 --no-pager; }
restart_cmd(){ need_root; local s; s=$(service_name); [[ -n $s ]] || die "Runner service not found"; systemctl restart "$s"; status_cmd; }
doctor_cmd(){
  need_root; local s fail=0; s=$(service_name)
  free -h; df -h "$INSTALL_DIR" 2>/dev/null || df -h /
  [[ -f "$INSTALL_DIR/.runner" ]] || { warn "Missing .runner"; fail=1; }
  [[ -n $s ]] && systemctl is-active --quiet "$s" || { warn "Service inactive"; fail=1; }
  curl -fsS --connect-timeout 10 https://github.com/ >/dev/null || { warn "github.com:443 unavailable"; fail=1; }
  curl -fsS --connect-timeout 10 https://api.github.com/meta >/dev/null || { warn "api.github.com:443 unavailable"; fail=1; }
  ((fail==0)) || die "Doctor failed"; log "Doctor passed"
}

uninstall_cmd(){
  need_root; [[ -d $INSTALL_DIR ]] || die "Install directory not found"
  [[ -n $ORG ]] || { local u; u=$(runner_field gitHubUrl); ORG=${u##*/}; }
  local s; s=$(service_name); [[ -n $s ]] && systemctl stop "$s" || true
  [[ -x "$INSTALL_DIR/svc.sh" ]] && (cd "$INSTALL_DIR" && ./svc.sh uninstall) || true
  if ((!LOCAL_ONLY)) && [[ -f "$INSTALL_DIR/.runner" ]]; then local rem; rem=$(api_token remove-token); runuser -u "$USER_NAME" -- env HOME="/home/$USER_NAME" "$INSTALL_DIR/config.sh" remove --token "$rem"; fi
  if ((PURGE)); then confirm "Delete $INSTALL_DIR and $USER_NAME?" || die "Cancelled"; rm -rf "$INSTALL_DIR"; id "$USER_NAME" >/dev/null 2>&1 && userdel -r "$USER_NAME" || true; fi
  log "Uninstalled"
}

case "$CMD" in
  install) install_cmd;; status) status_cmd;; doctor) doctor_cmd;; logs) logs_cmd;; restart) restart_cmd;; uninstall) uninstall_cmd;;
  help|-h|--help) usage;; version|--version) echo "$VERSION";; *) die "Unknown command: $CMD";;
esac
