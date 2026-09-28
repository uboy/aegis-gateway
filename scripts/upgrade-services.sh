#!/usr/bin/env bash
# scripts/upgrade-services.sh - Orchestrator for safe automated upgrades
# of Aegis Gateway system packages and non-APT edge proxy services.
set -euo pipefail

SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/upgrade.sh"

LOCK_FILE="/run/lock/aegis-upgrade.lock"
MODE="run"
TARGET_SERVICE="all"

usage() {
  cat <<EOF
Использование: $0 [ПАРАМЕТРЫ]

Параметры:
  --check               Только проверить доступные обновления (без применения)
  --service <имя>       Обновить только указанную службу (apt | caddy | dumbproxy)
  --all                 Обновить все доступные компоненты (по умолчанию)
  -h, --help            Показать эту справку
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --service)
      TARGET_SERVICE="$2"
      shift 2
      ;;
    --all)
      TARGET_SERVICE="all"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      error "Неизвестный параметр: $1"
      usage
      ;;
  esac
done

# Ensure single instance execution via flock
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  warn "Другой процесс обновления Aegis Gateway уже запущен. Выход."
  exit 0
fi

log "=== Запуск Aegis Safe Upgrade Pipeline (Режим: ${MODE}, Цель: ${TARGET_SERVICE}) ==="

ERRORS=0

run_service_upgrade() {
  local svc="$1"
  log "--- Обработка компонента: ${svc} ---"
  case "$svc" in
    apt)
      upgrade_system_apt "$MODE" || (( ERRORS++ ))
      ;;
    caddy)
      upgrade_caddy "$MODE" || (( ERRORS++ ))
      ;;
    dumbproxy)
      upgrade_dumbproxy "$MODE" || (( ERRORS++ ))
      ;;
    *)
      error "Неизвестный сервис: $svc"
      (( ERRORS++ ))
      ;;
  esac
}

if [[ "$TARGET_SERVICE" == "all" ]]; then
  run_service_upgrade "apt"
  run_service_upgrade "caddy"
  run_service_upgrade "dumbproxy"
else
  run_service_upgrade "$TARGET_SERVICE"
fi

if (( ERRORS > 0 )); then
  error "=== Завершено с ошибками (${ERRORS} сбоев). Проверьте системные логи. ==="
  exit 1
fi

success "=== Все процедуры обновления успешно завершены. ==="
exit 0
