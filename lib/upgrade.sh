#!/usr/bin/env bash
# lib/upgrade.sh - Safe upgrade engine with pre-flight validation,
# atomic swap, and automated fallback/rollback for Aegis Gateway services.

# Load libraries if not already loaded
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${LIB_DIR}/common.sh" ]] && source "${LIB_DIR}/common.sh"
[[ -f "${LIB_DIR}/utils.sh" ]] && source "${LIB_DIR}/utils.sh"

DEFAULT_HEALTH_TIMEOUT=15

# Safe atomic upgrade runner with automatic rollback
# Usage: aegis_safe_binary_upgrade NAME TARGET_PATH STAGING_PATH TEST_CMD SERVICES_LIST [HEALTH_FN] [TIMEOUT]
aegis_safe_binary_upgrade() {
  local name="$1"
  local target_path="$2"
  local staging_path="$3"
  local test_cmd="$4"
  local services="$5"
  local health_fn="${6:-}"
  local timeout="${7:-$DEFAULT_HEALTH_TIMEOUT}"

  log "Начало безопасного обновления компонента: ${name}..."

  # 1. Pre-flight checks on staging binary
  if [[ ! -f "$staging_path" ]]; then
    error "Staging-файл не найден: $staging_path"
    return 1
  fi
  chmod 755 "$staging_path"

  log "Pre-flight проверка staging-бинарника..."
  if ! eval "$test_cmd \"$staging_path\"" >/dev/null 2>&1; then
    error "Pre-flight проверка провалена для $staging_path! Обновление отменено."
    rm -rf "$staging_path"
    return 1
  fi
  success "Pre-flight проверка пройдена."

  # 2. Atomic backup of current binary
  local bak_path="${target_path}.bak"
  if [[ -f "$target_path" ]]; then
    cp -p "$target_path" "$bak_path"
    log "Создана резервная копия: ${bak_path}"
  fi

  # 3. Atomic swap
  mv "$staging_path" "$target_path"
  chmod 755 "$target_path"
  log "Бинарник заменён на новую версию."

  # 4. Restart dependent services
  log "Перезапуск связанных служб: ${services}..."
  # shellcheck disable=SC2086
  if ! systemctl restart $services 2>/dev/null; then
    warn "Перезапуск одной из служб завершился ошибкой. Запуск процедуры отката..."
    _aegis_rollback_binary "$target_path" "$bak_path" "$services"
    return 1
  fi

  # 5. Post-restart health check with timeout
  log "Health-check сервисов (таймаут: ${timeout}с)..."
  local elapsed=0
  local all_healthy=false

  while (( elapsed < timeout )); do
    all_healthy=true
    for svc in $services; do
      if ! systemctl is-active --quiet "$svc"; then
        all_healthy=false
        break
      fi
    done

    if [[ "$all_healthy" == "true" && -n "$health_fn" ]]; then
      if ! eval "$health_fn"; then
        all_healthy=false
      fi
    fi

    if [[ "$all_healthy" == "true" ]]; then
      break
    fi

    sleep 1
    (( elapsed++ ))
  done

  # 6. Fallback trigger if health-check failed
  if [[ "$all_healthy" != "true" ]]; then
    error "КРИТИЧЕСКИЙ СБОЙ: Health-check не пройден за ${timeout}с!"
    _aegis_rollback_binary "$target_path" "$bak_path" "$services"
    return 1
  fi

  success "Обновление ${name} успешно завершено и проверено (health-check PASS)."
  return 0
}

_aegis_rollback_binary() {
  local target_path="$1"
  local bak_path="$2"
  local services="$3"

  error "=== ИНИЦИИРОВАН АВТОМАТИЧЕСКИЙ ОТКАТ (ROLLBACK) ==="
  if [[ -f "$bak_path" ]]; then
    local tmp_rollback="${target_path}.rollback_tmp"
    cp -p "$bak_path" "$tmp_rollback"
    mv -f "$tmp_rollback" "$target_path"
    chmod 755 "$target_path"
    log "Восстановлен предыдущий бинарник из ${bak_path}."
    # shellcheck disable=SC2086
    systemctl restart $services 2>/dev/null || true
    log "Службы перезапущены на предыдущей стабильной версии."
  else
    error "Резервная копия ${bak_path} не найдена! Требуется ручное вмешательство."
  fi
}

# --- Service specific handlers ---

upgrade_caddy() {
  local mode="${1:-run}" # check | run
  if ! command -v caddy >/dev/null 2>&1; then
    warn "Caddy не установлен."
    return 0
  fi

  local current_ver
  current_ver=$(caddy version 2>&1 | awk '{print $1}')
  log "Текущая версия Caddy: ${current_ver}"

  if [[ "$mode" == "check" ]]; then
    log "Режим проверки: caddy upgrade --dry-run / проверка..."
    return 0
  fi

  # Validate config first before touching binary
  if [[ -f /etc/caddy/Caddyfile ]]; then
    log "Валидация /etc/caddy/Caddyfile..."
    # Import systemd environment if defined (e.g. drop-ins or service unit)
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
      local caddy_envs
      caddy_envs=$(systemctl show caddy --property=Environment --value 2>/dev/null || true)
      if [[ -n "$caddy_envs" ]]; then
        for ev in $caddy_envs; do
          export "$ev"
        done
      fi
    fi

    if ! caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      error "Текущий Caddyfile содержит ошибки синтаксиса. Апгрейд заблокирован."
      return 1
    fi
  fi

  local caddy_bin
  caddy_bin="$(which caddy)"
  local caddy_bak="${caddy_bin}.bak"
  cp -p "$caddy_bin" "$caddy_bak"

  log "Запуск caddy upgrade..."
  if ! caddy upgrade; then
    warn "caddy upgrade завершился с ошибкой."
    return 1
  fi
  chmod 755 "$caddy_bin"

  local new_ver
  new_ver=$(caddy version 2>&1 | awk '{print $1}')
  if [[ "$current_ver" == "$new_ver" ]]; then
    log "Caddy уже последней версии (${new_ver})."
    return 0
  fi

  log "Caddy обновлен: ${current_ver} -> ${new_ver}. Перезапуск службы caddy..."
  if ! systemctl restart caddy.service; then
    error "Служба caddy не запустилась после апгрейда! Откат..."
    local caddy_rollback="${caddy_bin}.rollback_tmp"
    cp -p "$caddy_bak" "$caddy_rollback"
    mv -f "$caddy_rollback" "$caddy_bin"
    chmod 755 "$caddy_bin"
    systemctl restart caddy.service
    return 1
  fi

  success "Caddy успешно обновлен и активен."
}

upgrade_dumbproxy() {
  local mode="${1:-run}"
  local target_bin="/usr/local/bin/dumbproxy"
  if [[ ! -x "$target_bin" ]]; then
    warn "dumbproxy не найден по пути ${target_bin}."
    return 0
  fi

  local current_ver
  current_ver=$("$target_bin" -version 2>&1 | awk '{print $1}' || echo "none")
  log "Текущая версия dumbproxy: ${current_ver}"

  log "Запрос последней версии dumbproxy на GitHub..."
  local latest_tag
  latest_tag=$(curl -fsSL --max-time 10 https://api.github.com/repos/Snawoot/dumbproxy/releases/latest 2>/dev/null \
    | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)

  if [[ -z "$latest_tag" ]]; then
    warn "Не удалось получить информацию о релизах dumbproxy с GitHub."
    return 0
  fi

  if [[ "$current_ver" == "$latest_tag" || "v${current_ver}" == "$latest_tag" ]]; then
    log "dumbproxy уже последней версии (${latest_tag})."
    return 0
  fi

  log "Доступно обновление dumbproxy: ${current_ver} -> ${latest_tag}"
  if [[ "$mode" == "check" ]]; then
    return 0
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  local download_url="https://github.com/Snawoot/dumbproxy/releases/download/${latest_tag}/dumbproxy.linux-amd64"
  log "Скачивание ${download_url}..."
  if ! curl -fsSL --max-time 30 "$download_url" -o "${tmp_dir}/dumbproxy"; then
    error "Ошибка загрузки dumbproxy."
    rm -rf "$tmp_dir"
    return 1
  fi

  # Health check lambda: verifies 127.0.0.1:10802 is open
  local health_fn="ss -tuln 2>/dev/null | grep -q ':10802'"
  local candidate_services=("dumbproxy.service" "dumbproxy-tg.service" "dumbproxy-10802.service")
  local active_services=()
  for s in "${candidate_services[@]}"; do
    if systemctl list-unit-files "$s" >/dev/null 2>&1; then
      active_services+=("$s")
    fi
  done
  local services="${active_services[*]:-dumbproxy.service}"

  aegis_safe_binary_upgrade "dumbproxy" "$target_bin" "${tmp_dir}/dumbproxy" \
    "\"\$1\" -version" "$services" "$health_fn" 15
  local rc=$?
  rm -rf "$tmp_dir"
  return "$rc"
}

upgrade_system_apt() {
  local mode="${1:-run}"
  log "Проверка системных APT пакетов..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  local upgradable
  upgradable=$(apt-get -s upgrade 2>/dev/null | grep -P "^\d+ upgraded" || true)
  log "Состояние APT: ${upgradable:-нет обновлений}"

  if [[ "$mode" == "check" ]]; then
    return 0
  fi

  if [[ -n "$upgradable" && "$upgradable" != "0 upgraded"* ]]; then
    log "Установка системных обновлений..."
    apt-get upgrade -y
    apt-get autoclean -y
    apt-get autoremove --purge -y
    success "Системные пакеты обновлены."
  else
    log "Системные пакеты не требуют обновления."
  fi
}
