#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"
COMPOSE_FILE="${ROOT_DIR}/compose.yaml"

log() { printf '[stack] %s\n' "$*"; }
warn() { printf '[stack] WARNING: %s\n' "$*" >&2; }
die() { printf '[stack] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash stack.sh install [profiles]
  sudo bash stack.sh up [profiles]
  sudo bash stack.sh down
  sudo bash stack.sh restart [profiles]
  sudo bash stack.sh status
  sudo bash stack.sh logs [service]
  sudo bash stack.sh backup
  sudo bash stack.sh restore <backup.dump> --yes
  sudo bash stack.sh update [profiles]
  sudo bash stack.sh doctor
  sudo bash stack.sh uninstall --yes [--purge-data]

Profiles:
  tools   Start Adminer on the configured loopback address.
  cache   Start Valkey on the configured loopback address.
  tools,cache can be supplied together.
USAGE
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this command with sudo or as root."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_runtime() {
  require_command docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not available. Check 1Panel/Docker first."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    require_command od
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

replace_env_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

ensure_env() {
  [[ -f "$ENV_EXAMPLE" ]] || die "Missing $ENV_EXAMPLE"
  if [[ ! -f "$ENV_FILE" ]]; then
    install -m 600 "$ENV_EXAMPLE" "$ENV_FILE"
    replace_env_value POSTGRES_PASSWORD "$(generate_secret)"
    replace_env_value VALKEY_PASSWORD "$(generate_secret)"
    log "Created local configuration: $ENV_FILE"
  fi

  chmod 600 "$ENV_FILE"
  grep -q '^POSTGRES_PASSWORD=GENERATED_ON_INSTALL$' "$ENV_FILE" && \
    replace_env_value POSTGRES_PASSWORD "$(generate_secret)"
  grep -q '^VALKEY_PASSWORD=GENERATED_ON_INSTALL$' "$ENV_FILE" && \
    replace_env_value VALKEY_PASSWORD "$(generate_secret)"
}

load_env() {
  ensure_env
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  : "${STACK_NAME:?STACK_NAME is required}"
  : "${DOCKER_NETWORK_NAME:?DOCKER_NETWORK_NAME is required}"
  : "${BACKUP_DIR:?BACKUP_DIR is required}"
  : "${BACKUP_RETENTION_DAYS:?BACKUP_RETENTION_DAYS is required}"
  : "${POSTGRES_DB:?POSTGRES_DB is required}"
  : "${POSTGRES_USER:?POSTGRES_USER is required}"
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
}

dc() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

validate_profiles() {
  local profiles="${1:-}"
  [[ -z "$profiles" ]] && return 0
  [[ "$profiles" =~ ^(tools|cache)(,(tools|cache))*$ ]] || \
    die "Invalid profiles: $profiles. Use tools, cache, or tools,cache."
}

compose_pull() {
  local profiles="${1:-}"
  validate_profiles "$profiles"
  if [[ -n "$profiles" ]]; then
    COMPOSE_PROFILES="$profiles" dc pull
  else
    dc pull
  fi
}

compose_up() {
  local profiles="${1:-}"
  validate_profiles "$profiles"
  if [[ -n "$profiles" ]]; then
    COMPOSE_PROFILES="$profiles" dc up -d --remove-orphans
  else
    dc up -d --remove-orphans
  fi
}

wait_for_postgres() {
  local cid status attempts=0
  cid="$(dc ps -q postgres)"
  [[ -n "$cid" ]] || die "PostgreSQL container was not created."
  while (( attempts < 30 )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
    if [[ "$status" == "healthy" ]]; then
      log "PostgreSQL is healthy."
      return 0
    fi
    [[ "$status" == "unhealthy" || "$status" == "exited" ]] && \
      die "PostgreSQL failed health checks. Run: sudo bash stack.sh logs postgres"
    sleep 2
    attempts=$((attempts + 1))
  done
  die "Timed out waiting for PostgreSQL health check."
}

rotate_backups() {
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' \
    -mtime "+${BACKUP_RETENTION_DAYS}" -delete
}

cmd_install() {
  local profiles="${1:-}"
  require_root
  check_runtime
  load_env
  install -d -m 700 "$BACKUP_DIR"
  dc config --quiet
  compose_pull "$profiles"
  compose_up "$profiles"
  wait_for_postgres
  log "Installation completed."
  log "Secrets remain only in $ENV_FILE and were not printed."
  log "Database is bound to ${POSTGRES_BIND_IP}:${POSTGRES_PORT}."
}

cmd_up() {
  local profiles="${1:-}"
  require_root
  check_runtime
  load_env
  compose_up "$profiles"
  wait_for_postgres
}

cmd_down() {
  require_root
  check_runtime
  load_env
  dc down
}

cmd_restart() {
  local profiles="${1:-}"
  require_root
  check_runtime
  load_env
  dc down
  compose_up "$profiles"
  wait_for_postgres
}

cmd_status() {
  require_root
  check_runtime
  load_env
  dc ps
}

cmd_logs() {
  local service="${1:-}"
  require_root
  check_runtime
  load_env
  if [[ -n "$service" ]]; then
    dc logs --tail=200 "$service"
  else
    dc logs --tail=200
  fi
}

cmd_backup() {
  local timestamp target tmp
  require_root
  check_runtime
  load_env
  install -d -m 700 "$BACKUP_DIR"
  wait_for_postgres
  timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  target="${BACKUP_DIR}/${STACK_NAME}-${timestamp}.dump"
  tmp="${target}.tmp"
  if ! dc exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$tmp"; then
    rm -f "$tmp"
    die "PostgreSQL backup failed."
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Backup file is empty."; }
  if ! dc exec -T postgres pg_restore -l < "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "Backup validation failed."
  fi
  mv "$tmp" "$target"
  chmod 600 "$target"
  rotate_backups
  log "Backup created: $target"
}

cmd_restore() {
  local source_file="${1:-}" confirmation="${2:-}"
  require_root
  check_runtime
  load_env
  [[ -n "$source_file" ]] || die "Provide a .dump backup file."
  [[ "$confirmation" == "--yes" ]] || die "Restore is destructive. Re-run with --yes."
  [[ -f "$source_file" ]] || die "Backup not found: $source_file"
  wait_for_postgres
  dc exec -T postgres pg_restore -l < "$source_file" >/dev/null || die "Backup validation failed."
  warn "Restoring into the existing PostgreSQL database. Existing objects may be replaced."
  dc exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --exit-on-error < "$source_file"
  log "Restore completed."
}

cmd_update() {
  local profiles="${1:-}"
  require_root
  check_runtime
  load_env
  cmd_backup
  compose_pull "$profiles"
  compose_up "$profiles"
  wait_for_postgres
  log "Images updated and services restarted."
}

cmd_doctor() {
  require_root
  check_runtime
  load_env
  printf '%s\n' '--- Docker ---'
  docker version --format 'Client: {{.Client.Version}} | Server: {{.Server.Version}}'
  docker compose version
  printf '%s\n' '--- Compose validation ---'
  dc config --quiet && printf '%s\n' 'compose.yaml: OK'
  printf '%s\n' '--- Services ---'
  dc ps
  printf '%s\n' '--- Disk ---'
  df -h "$ROOT_DIR" "$BACKUP_DIR" 2>/dev/null || true
  printf '%s\n' '--- Network ---'
  docker network inspect "$DOCKER_NETWORK_NAME" --format 'Name={{.Name}} Containers={{len .Containers}}' 2>/dev/null || \
    warn "Network has not been created yet: $DOCKER_NETWORK_NAME"
  log "Doctor check finished. No secret values were printed."
}

cmd_uninstall() {
  local confirmation="${1:-}" purge="${2:-}"
  require_root
  check_runtime
  load_env
  [[ "$confirmation" == "--yes" ]] || die "Re-run uninstall with --yes."
  if [[ "$purge" == "--purge-data" ]]; then
    cmd_backup
    dc down --volumes --remove-orphans
    warn "Docker volumes were removed after a final backup."
  else
    dc down --remove-orphans
    log "Containers removed; persistent volumes and backups were kept."
  fi
}

main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    install) cmd_install "${1:-}" ;;
    up) cmd_up "${1:-}" ;;
    down) cmd_down ;;
    restart) cmd_restart "${1:-}" ;;
    status) cmd_status ;;
    logs) cmd_logs "${1:-}" ;;
    backup) cmd_backup ;;
    restore) cmd_restore "${1:-}" "${2:-}" ;;
    update) cmd_update "${1:-}" ;;
    doctor) cmd_doctor ;;
    uninstall) cmd_uninstall "${1:-}" "${2:-}" ;;
    -h|--help|help|'') usage ;;
    *) usage; die "Unknown command: $command" ;;
  esac
}

main "$@"
