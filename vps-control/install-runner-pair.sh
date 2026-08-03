#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$ROOT_DIR/install-github-runner.sh"

RUNNER_URL=""
CI_TOKEN_FILE=""
DEPLOY_TOKEN_FILE=""
NAME_PREFIX="$(hostname -s)"
CI_USER="github-ci"
DEPLOY_USER="github-deploy"
CI_DIR="/srv/github-runner-ci"
DEPLOY_DIR="/srv/github-runner-deploy"
CI_LABEL="axymorrsen-ci"
DEPLOY_LABEL="axymorrsen-deploy"

log() { printf '[runner-pair] %s\n' "$*"; }
die() { printf '[runner-pair] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-control/install-runner-pair.sh \
    --url https://github.com/OWNER/REPOSITORY \
    --ci-token-file /root/project-ci-token \
    --deploy-token-file /root/project-deploy-token

Options:
  --url <url>                 GitHub repository or organization URL
  --ci-token-file <path>      One-time registration token file for validation Runner
  --deploy-token-file <path>  One-time registration token file for deployment Runner
  --name-prefix <name>        Runner name prefix. Default: host short name
  --ci-user <name>            Default: github-ci
  --deploy-user <name>        Default: github-deploy
  --ci-dir <path>             Default: /srv/github-runner-ci
  --deploy-dir <path>         Default: /srv/github-runner-deploy
  --ci-label <label>          Default: axymorrsen-ci
  --deploy-label <label>      Default: axymorrsen-deploy
  -h, --help                  Show this help

The two token files must contain separately generated one-time registration
tokens. Both files are destroyed by the underlying installer after successful
registration. Validation and deployment are intentionally installed under
different Linux users and directories.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || die "--url requires a value"
      RUNNER_URL="$2"
      shift 2
      ;;
    --ci-token-file)
      [[ $# -ge 2 ]] || die "--ci-token-file requires a value"
      CI_TOKEN_FILE="$2"
      shift 2
      ;;
    --deploy-token-file)
      [[ $# -ge 2 ]] || die "--deploy-token-file requires a value"
      DEPLOY_TOKEN_FILE="$2"
      shift 2
      ;;
    --name-prefix)
      [[ $# -ge 2 ]] || die "--name-prefix requires a value"
      NAME_PREFIX="$2"
      shift 2
      ;;
    --ci-user)
      [[ $# -ge 2 ]] || die "--ci-user requires a value"
      CI_USER="$2"
      shift 2
      ;;
    --deploy-user)
      [[ $# -ge 2 ]] || die "--deploy-user requires a value"
      DEPLOY_USER="$2"
      shift 2
      ;;
    --ci-dir)
      [[ $# -ge 2 ]] || die "--ci-dir requires a value"
      CI_DIR="$2"
      shift 2
      ;;
    --deploy-dir)
      [[ $# -ge 2 ]] || die "--deploy-dir requires a value"
      DEPLOY_DIR="$2"
      shift 2
      ;;
    --ci-label)
      [[ $# -ge 2 ]] || die "--ci-label requires a value"
      CI_LABEL="$2"
      shift 2
      ;;
    --deploy-label)
      [[ $# -ge 2 ]] || die "--deploy-label requires a value"
      DEPLOY_LABEL="$2"
      shift 2
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
[[ -x "$INSTALLER" || -f "$INSTALLER" ]] || die "Missing installer: $INSTALLER"
[[ -n "$RUNNER_URL" ]] || die "--url is required"
[[ -n "$CI_TOKEN_FILE" ]] || die "--ci-token-file is required"
[[ -n "$DEPLOY_TOKEN_FILE" ]] || die "--deploy-token-file is required"
[[ "$CI_TOKEN_FILE" != "$DEPLOY_TOKEN_FILE" ]] || die "CI and deploy token files must be different"
[[ "$CI_USER" != "$DEPLOY_USER" ]] || die "CI and deploy users must be different"
[[ "$CI_DIR" != "$DEPLOY_DIR" ]] || die "CI and deploy directories must be different"
[[ "$CI_LABEL" != "$DEPLOY_LABEL" ]] || die "CI and deploy labels must be different"
[[ "$NAME_PREFIX" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid name prefix: $NAME_PREFIX"

log "Installing validation Runner as $CI_USER in $CI_DIR"
bash "$INSTALLER" \
  --url "$RUNNER_URL" \
  --token-file "$CI_TOKEN_FILE" \
  --user "$CI_USER" \
  --dir "$CI_DIR" \
  --name "${NAME_PREFIX}-ci-01" \
  --labels "$CI_LABEL"

log "Installing deployment Runner as $DEPLOY_USER in $DEPLOY_DIR"
bash "$INSTALLER" \
  --url "$RUNNER_URL" \
  --token-file "$DEPLOY_TOKEN_FILE" \
  --user "$DEPLOY_USER" \
  --dir "$DEPLOY_DIR" \
  --name "${NAME_PREFIX}-deploy-01" \
  --labels "$DEPLOY_LABEL"

log "Runner pair installed successfully."
log "Validation: user=$CI_USER dir=$CI_DIR label=$CI_LABEL"
log "Deployment: user=$DEPLOY_USER dir=$DEPLOY_DIR label=$DEPLOY_LABEL"
