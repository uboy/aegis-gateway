#!/usr/bin/env bash
set -Eeuo pipefail

# Root directory of the installer
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries - ПРОВЕРКА НАЛИЧИЯ
for f in common.sh state.sh utils.sh ui.sh firewall.sh cert.sh; do
    if [[ ! -f "${SCRIPT_DIR}/lib/$f" ]]; then
        echo "ERROR: Library ${SCRIPT_DIR}/lib/$f not found!"
        exit 1
    fi
    source "${SCRIPT_DIR}/lib/$f"
done

# Source modules
for f in base.sh hardening.sh xui.sh openvpn.sh openconnect.sh amnezia.sh dumbproxy.sh mtproto.sh tproxy_server.sh warp_telegram.sh; do
    if [[ ! -f "${SCRIPT_DIR}/modules/$f" ]]; then
        echo "ERROR: Module ${SCRIPT_DIR}/modules/$f not found!"
        exit 1
    fi
    source "${SCRIPT_DIR}/modules/$f"
done

on_exit() {
  local rc=$?
  save_install_state
  trap - EXIT
  exit "$rc"
}
trap on_exit EXIT

on_error() {
  local rc=$? line=$1
  trap - ERR EXIT
  error "Installation failed at line $line (exit code $rc)"
  [[ -f /etc/ufw/before.rules.orig ]] && \
    cp /etc/ufw/before.rules.orig /etc/ufw/before.rules
  save_install_state
  exit "$rc"
}
trap 'on_error ${LINENO}' ERR

main() {
  # Инициализация — все переменные пустые, чтобы resolve_var мог восстановить
  # значения из state-файла (не-пустая инициализация блокирует restore_var)
  DOMAIN=""
  EMAIL=""
  VPN_USER=""
  VPN_PASS=""
  VPN_EXCLUDE_ROUTES=""
  INSTALL_XUI="false"
  INSTALL_OPENVPN="false"
  INSTALL_OPENCONNECT="false"
  INSTALL_AMNEZIA="false"
  INSTALL_DUMBPROXY="false"
  INSTALL_MTPROXY="false"
  INSTALL_TPROXY="false"
  INSTALL_WARP_TELEGRAM="false"
  INSTALL_HARDENING="false"
  INSTALL_MODE=""
  SSH_PORT=""
  PORT_XUI_PANEL=""
  PORT_XUI_REALITY=""
  PORT_OPENVPN=""
  PORT_OPENCONNECT=""
  PORT_AMNEZIA=""
  PORT_DUMBPROXY=""
  PORT_MTPROXY=""
  PORT_MTPROXY_STATS=""
  MTPROXY_SECRET=""
  NEW_USER=""
  NEW_PASS=""
  PANEL_ADMIN_USER=""
  PANEL_ADMIN_PASS=""
  EXPOSE_PANEL_PUBLIC=""
  PANEL_PUBLIC_HOST=""

  log "Шаг 1: Проверка ОС и загрузка состояния..."
  module_base_check_os
  load_install_state

  resolve_var DOMAIN             ""
  resolve_var EMAIL              ""
  resolve_var VPN_USER           "vpnuser"
  resolve_var VPN_PASS           ""
  resolve_var VPN_EXCLUDE_ROUTES ""
  resolve_var INSTALL_MODE       "simple"
  resolve_var SSH_PORT           "22"
  resolve_var NEW_USER           ""
  resolve_var NEW_PASS           ""
  resolve_var PANEL_ADMIN_USER   ""
  resolve_var PANEL_ADMIN_PASS   ""
  resolve_var INSTALL_HARDENING  "false"
  resolve_var EXPOSE_PANEL_PUBLIC "false"
  resolve_var PANEL_PUBLIC_HOST   ""
  resolve_var PORT_XUI_PANEL     "2053"
  resolve_var PORT_XUI_REALITY   "443"
  resolve_var PORT_OPENVPN       "1194"
  resolve_var PORT_OPENCONNECT   "4443"
  resolve_var PORT_AMNEZIA       "39442"
  resolve_var PORT_DUMBPROXY     "8080"
  resolve_var PORT_MTPROXY       "8443"
  resolve_var PORT_MTPROXY_STATS "8888"
  resolve_var INSTALL_DUMBPROXY "false"
  resolve_var INSTALL_MTPROXY   "false"
  resolve_var INSTALL_TPROXY    "false"
  resolve_var INSTALL_WARP_TELEGRAM "false"
  resolve_var MTPROXY_SECRET    ""
  resolve_var MTPROXY_DOMAIN    ""
  resolve_var TPROXY_DOMAIN     ""

  if ! command -v whiptail &>/dev/null; then
    log "Установка whiptail (интерактивный интерфейс)..."
    apt-get install -y --no-install-recommends whiptail >/dev/null 2>&1
  fi

  ui_banner

  log "Шаг 2: Сбор интерактивной информации..."
  ui_select_components
  ui_get_basic_info
  ui_get_hardening_info
  ui_get_panel_exposure_info
  ui_get_ports
  ui_get_mtproto_domain

  log "Шаг 3: Подтверждение и начало установки..."
  ui_confirm_install
  
  # Проверка конфликтов портов
  declare -A USED_PORTS
  [[ "${INSTALL_XUI:-false}" == "true" ]] && {
    USED_PORTS["${PORT_XUI_REALITY:-443}"]="3x-ui Reality"
    USED_PORTS["${PORT_XUI_PANEL:-2053}"]="3x-ui Panel"
  }
  [[ "${INSTALL_OPENVPN:-false}" == "true" ]] && USED_PORTS["${PORT_OPENVPN:-1194}"]="OpenVPN"
  [[ "${INSTALL_OPENCONNECT:-false}" == "true" ]] && USED_PORTS["${PORT_OPENCONNECT:-4443}"]="OpenConnect"
  [[ "${INSTALL_AMNEZIA:-false}" == "true" ]] && USED_PORTS["${PORT_AMNEZIA:-39442}"]="AmneziaWG"
  [[ "${INSTALL_DUMBPROXY:-false}" == "true" ]] && USED_PORTS["${PORT_DUMBPROXY:-8080}"]="Dumbproxy"
  if [[ "${INSTALL_MTPROXY:-false}" == "true" ]]; then
    if [[ -n "${USED_PORTS[$PORT_MTPROXY]:-}" ]] || ! check_port_free "$PORT_MTPROXY"; then
      if [[ "$PORT_MTPROXY" == "8443" && -z "${STATE_VALUES[PORT_MTPROXY]+x}" ]]; then
        # Only the untouched default on a fresh install may be silently
        # reassigned; an explicit choice or a value restored from a prior
        # install is never auto-replaced (see mtproto_runbook.md).
        MTPROXY_FALLBACK_PORT=""
        if MTPROXY_FALLBACK_PORT=$(pick_free_port_from_candidates USED_PORTS 9443 2083 2087 2096); then
          warn "Порт MTProto 8443 занят, выбран запасной порт ${MTPROXY_FALLBACK_PORT}/TCP."
          PORT_MTPROXY="$MTPROXY_FALLBACK_PORT"
        else
          error "КОНФЛИКТ ПОРТОВ: порт MTProto 8443 и все запасные порты (9443, 2083, 2087, 2096) заняты. Укажите порт MTProto вручную и повторите установку."
          exit 1
        fi
      else
        error "КОНФЛИКТ ПОРТОВ: порт MTProto ${PORT_MTPROXY} уже занят (${USED_PORTS[$PORT_MTPROXY]:-другим процессом на хосте}). Это явно выбранный или сохранённый порт, поэтому он не заменяется автоматически — смените PORT_MTPROXY и повторите установку."
        exit 1
      fi
    fi
    USED_PORTS["$PORT_MTPROXY"]="MTProto"
  fi
  
  # Если SSH_PORT изменен — проверяем конфликты
  if [[ "${SSH_PORT:-22}" != "22" ]]; then
      if [[ -n "${USED_PORTS[$SSH_PORT]:-}" ]]; then
          error "КОНФЛИКТ ПОРТОВ: Порт $SSH_PORT занят сервисом ${USED_PORTS[$SSH_PORT]}. Смените порт SSH!"
          exit 1
      fi
      if ! check_port_free "$SSH_PORT" && ! port_in_use_by_pattern "$SSH_PORT" "sshd" tcp; then
          error "Порт $SSH_PORT уже занят запущенным сервисом (проверено через ss)"
          exit 1
      fi
  fi

  # Проверка свободного места (минимум 5 ГБ)
  check_disk_space 2

  module_base_install
  firewall_init
  
  if [[ "${INSTALL_HARDENING:-false}" == "true" ]]; then
    log "Шаг 4: Настройка безопасности..."
    module_hardening_apply
  fi
  
  if [[ "$INSTALL_XUI" == "true" || "$INSTALL_OPENCONNECT" == "true" ]]; then
    log "Шаг 5: Получение сертификатов..."
    cert_install_tools
    cert_issue_standalone "$DOMAIN" "$EMAIL"
  fi

  log "Шаг 6: Установка компонентов..."
  if [[ "$INSTALL_XUI" == "true" ]]; then 
    module_xui_install
    if [[ "$INSTALL_XUI" != "skipped" ]]; then module_xui_configure; fi
  fi
  if [[ "$INSTALL_OPENVPN" == "true" ]]; then 
    module_openvpn_install
    if [[ "$INSTALL_OPENVPN" != "skipped" ]]; then module_openvpn_configure; fi
  fi
  if [[ "$INSTALL_OPENCONNECT" == "true" ]]; then module_openconnect_install; fi
  if [[ "$INSTALL_AMNEZIA" == "true" ]]; then module_amnezia_install; fi
  if [[ "$INSTALL_DUMBPROXY" == "true" ]]; then module_dumbproxy_install; fi
  if [[ "$INSTALL_MTPROXY" == "true" ]]; then module_mtproto_install; fi
  if [[ "$INSTALL_TPROXY" == "true" ]]; then module_tproxy_server_install; fi
  if [[ "$INSTALL_WARP_TELEGRAM" == "true" ]]; then module_warp_telegram_install; fi

  log "Шаг 7: Настройка фаервола..."
  firewall_allow "${SSH_PORT:-22}"
  if [[ "${INSTALL_XUI:-false}" == "true" ]]; then
    firewall_allow "${PORT_XUI_REALITY:-443}" tcp
  fi
  if [[ "${INSTALL_XUI:-false}" == "true" && "${EXPOSE_PANEL_PUBLIC:-false}" == "true" && "${INSTALL_HARDENING:-false}" != "true" ]]; then
    firewall_allow "${PORT_XUI_PANEL:-2053}" tcp
  fi
  firewall_enable
  
  if [[ "$INSTALL_MODE" == "super-secure" ]]; then
     systemctl restart ssh || true
  fi

  log "Шаг 8: Завершение..."
  if [[ -f "${SCRIPT_DIR}/scripts/upgrade-services.sh" ]]; then
    chmod +x "${SCRIPT_DIR}/scripts/upgrade-services.sh"
    ln -sf "${SCRIPT_DIR}/scripts/upgrade-services.sh" /usr/local/bin/aegis-upgrade-services
    if [[ -f "${SCRIPT_DIR}/systemd/aegis-upgrade.service" && -f "${SCRIPT_DIR}/systemd/aegis-upgrade.timer" ]]; then
      cp "${SCRIPT_DIR}/systemd/aegis-upgrade.service" /etc/systemd/system/
      cp "${SCRIPT_DIR}/systemd/aegis-upgrade.timer" /etc/systemd/system/
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now aegis-upgrade.timer >/dev/null 2>&1 || true
    fi
  fi
  ui_final_report
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
