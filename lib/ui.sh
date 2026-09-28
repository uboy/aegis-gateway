#!/usr/bin/env bash

# Библиотека для работы с whiptail (стандартное меню в Ubuntu)
# ANSI constants are defined in common.sh (sourced before this file)

ui_banner() {
    clear
    cat << "EOF"
    ___              _      _   __ ____  _   __
   /   | ___  ____ _(_)____| | / // __ \/ | / /
  / /| |/ _ \/ __ `/ / ___/| |/ // /_/ /  |/ /
 / ___ /  __/ /_/ / (__  ) |  // ____/ /|  /
/_/  |_\___/\__, /_/____/  |_//_/   /_/ |_/
           /____/     GATEWAY
EOF
    printf "${BLUE}${BOLD}      --- Aegis Gateway ---${NC}\n"
}

ui_port_reusable_for_selected_service() {
    local var_name="$1"
    local port="$2"

    case "$var_name" in
        PORT_XUI_PANEL|PORT_XUI_REALITY)
            docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^3x-ui$" || return 1
            port_in_use_by_pattern "$port" "docker-proxy|dockerd|3x-ui|x-ui" tcp
            ;;
        PORT_OPENVPN)
            docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^dockovpn$" || return 1
            port_in_use_by_pattern "$port" "docker-proxy|dockerd|dockovpn" udp
            ;;
        PORT_OPENCONNECT)
            (systemctl is-active --quiet ocserv 2>/dev/null || [[ -f /etc/ocserv/ocserv.conf ]]) || return 1
            port_in_use_by_pattern "$port" "ocserv" || return 1
            ;;
        PORT_AMNEZIA)
            (systemctl is-active --quiet awg-quick@awg0 2>/dev/null || [[ -f /etc/amnezia/amneziawg/awg0.conf ]]) || return 1
            [[ "$(awg show awg0 listen-port 2>/dev/null)" == "$port" ]]
            ;;
        PORT_DUMBPROXY)
            (systemctl is-active --quiet dumbproxy 2>/dev/null || [[ -x /usr/local/bin/dumbproxy ]]) || return 1
            port_in_use_by_pattern "$port" "dumbproxy" tcp
            ;;
        PORT_MTPROXY)
            (systemctl is-active --quiet mtproxy 2>/dev/null || [[ -x /opt/mtproxy/teleproxy || -x /opt/mtproxy/mtg ]]) || return 1
            port_in_use_by_pattern "$port" "teleproxy|mtg|mtproxy" tcp
            ;;
        *)
            return 1
            ;;
    esac
}

ui_select_components() {
    local choices
    choices=$(whiptail --title "Aegis Gateway - Выбор" --checklist \
    "Выберите компоненты для установки (Пробел - выбор, Enter - подтверждение):" 22 75 12 \
    "XUI" "3x-ui Panel (Xray/VLESS Reality)" ON \
    "Amnezia" "AmneziaWG защищенный туннель (UDP/39442)" ON \
    "OpenVPN" "Классический VPN (Legacy / Корпоративный доступ)" OFF \
    "OpenConnect" "Cisco AnyConnect совместимый VPN" OFF \
    "Dumbproxy" "HTTP/HTTPS прокси-сервер с авторизацией" OFF \
    "MTProto" "Telegram WebProxy и Fake-TLS (Единый порт 443)" OFF \
    "WARP" "Cloudflare WARP Egress туннель" OFF \
    "Hardening" "Усиление безопасности SSH/Fail2Ban/UFW" ON 3>&1 1>&2 2>&3) || exit 0

    # Сбрасываем флаги
    INSTALL_XUI="false"
    INSTALL_AMNEZIA="false"
    INSTALL_OPENVPN="false"
    INSTALL_OPENCONNECT="false"
    INSTALL_DUMBPROXY="false"
    INSTALL_TPROXY="false"
    INSTALL_MTPROXY="false"
    INSTALL_WARP_TELEGRAM="false"
    INSTALL_HARDENING="false"

    for choice in $choices; do
        case $choice in
            "\"XUI\"") INSTALL_XUI="true" ;;
            "\"Amnezia\"") INSTALL_AMNEZIA="true" ;;
            "\"OpenVPN\"") INSTALL_OPENVPN="true" ;;
            "\"OpenConnect\"") INSTALL_OPENCONNECT="true" ;;
            "\"Dumbproxy\"") INSTALL_DUMBPROXY="true" ;;
            "\"MTProto\"")
                INSTALL_TPROXY="true"
                INSTALL_MTPROXY="false"
                ;;
            "\"WARP\"") INSTALL_WARP_TELEGRAM="true" ;;
            "\"Hardening\"") INSTALL_HARDENING="true" ;;
        esac
    done

    # Если ничего не выбрано - выходим
    if [[ "$INSTALL_XUI" == "false" && "$INSTALL_AMNEZIA" == "false" && "$INSTALL_OPENVPN" == "false" && "$INSTALL_OPENCONNECT" == "false" && "$INSTALL_DUMBPROXY" == "false" && "$INSTALL_TPROXY" == "false" && "$INSTALL_MTPROXY" == "false" && "$INSTALL_WARP_TELEGRAM" == "false" && "$INSTALL_HARDENING" == "false" ]]; then
        whiptail --title "Ошибка" --msgbox "Ничего не выбрано. Установка отменена." 10 60
        exit 0
    fi
}

ui_get_basic_info() {
    # DOMAIN — loop until valid
    while true; do
        DOMAIN=$(whiptail --title "Настройка Aegis" --inputbox "Введите домен или IP адрес сервера:" 10 60 "${DOMAIN:-}" 3>&1 1>&2 2>&3) || exit 0
        if is_valid_domain "$DOMAIN"; then
            break
        fi
        whiptail --title "Ошибка" --msgbox "Некорректный домен или IP: '${DOMAIN}'\nПример: example.com или 1.2.3.4" 10 60
    done

    # EMAIL — required only for XUI or OpenConnect (Let's Encrypt)
    if [[ "${INSTALL_XUI:-false}" == "true" || "${INSTALL_OPENCONNECT:-false}" == "true" ]]; then
        while true; do
            EMAIL=$(whiptail --title "Настройка Email" --inputbox "Введите Email для Let's Encrypt:" 10 60 "${EMAIL:-}" 3>&1 1>&2 2>&3) || exit 0
            if is_valid_email "$EMAIL"; then
                break
            fi
            whiptail --title "Ошибка" --msgbox "Некорректный email: '${EMAIL}'\nПример: user@example.com" 10 60
        done
    fi

    # VPN_USER — нужен только для OpenVPN / OpenConnect / Dumbproxy
    if [[ "${INSTALL_OPENVPN:-false}" == "true" || "${INSTALL_OPENCONNECT:-false}" == "true" || "${INSTALL_DUMBPROXY:-false}" == "true" ]]; then
        while true; do
            VPN_USER=$(whiptail --title "VPN Пользователь" --inputbox "Введите имя пользователя для VPN:" 10 60 "${VPN_USER:-vpnuser}" 3>&1 1>&2 2>&3) || exit 0
            if is_valid_username "$VPN_USER"; then
                break
            fi
            whiptail --title "Ошибка" --msgbox "Некорректное имя пользователя: '${VPN_USER}'\nДопустимо: строчные буквы, цифры, _ и - (начало: буква или _). Макс. 32 символа." 12 60
        done
    fi

    # VPN_PASS — нужен только для OpenConnect
    if [[ "${INSTALL_OPENCONNECT:-false}" == "true" ]]; then
        while true; do
            VPN_PASS=$(whiptail --title "VPN Пароль" --passwordbox "Введите пароль для VPN (оставьте пустым для автогенерации, мин. 12 символов):" 10 60 3>&1 1>&2 2>&3) || exit 0
            if [[ -z "${VPN_PASS:-}" ]]; then
                VPN_PASS=$(generate_strong_secret)
                break
            elif (( ${#VPN_PASS} >= 12 )); then
                break
            fi
            whiptail --title "Ошибка" --msgbox "Пароль слишком короткий. Минимум 12 символов, либо оставьте пустым для автогенерации." 10 60
        done
    fi

    # VPN_EXCLUDE_ROUTES — нужен только для OpenVPN / OpenConnect
    if [[ "${INSTALL_OPENVPN:-false}" == "true" || "${INSTALL_OPENCONNECT:-false}" == "true" ]]; then
        while true; do
            VPN_EXCLUDE_ROUTES=$(whiptail --title "Исключения маршрутов" --inputbox "Введите через запятую сети для исключения из VPN (напр. 1.1.1.1/32, 10.0.0.0/8). По умолчанию 192.168.0.0/16 уже исключена." 12 60 "${VPN_EXCLUDE_ROUTES:-}" 3>&1 1>&2 2>&3) || exit 0
            if [[ -z "${VPN_EXCLUDE_ROUTES:-}" ]]; then
                break
            fi
            local _bad_cidr="" _cidr_token=""
            IFS=',' read -ra _cidr_tokens <<< "$VPN_EXCLUDE_ROUTES"
            for _cidr_token in "${_cidr_tokens[@]}"; do
                _cidr_token="${_cidr_token// /}"  # trim spaces
                [[ -z "$_cidr_token" ]] && continue
                if ! is_valid_cidr "$_cidr_token"; then
                    _bad_cidr="$_cidr_token"
                    break
                fi
            done
            if [[ -z "$_bad_cidr" ]]; then
                break
            fi
            whiptail --title "Ошибка" --msgbox "Некорректный CIDR: '${_bad_cidr}'\nПример: 10.0.0.0/8" 10 60
        done
    fi

    if [[ "${INSTALL_XUI:-false}" == "true" ]]; then
        while true; do
            PANEL_PUBLIC_HOST=$(whiptail --title "Адрес панели 3x-ui" \
                --inputbox "Введите адрес для подключения к панели (домен/IP).\nПусто = использовать основной DOMAIN (${DOMAIN})." \
                11 72 "${PANEL_PUBLIC_HOST:-$DOMAIN}" 3>&1 1>&2 2>&3) || exit 0
            [[ -z "${PANEL_PUBLIC_HOST:-}" ]] && PANEL_PUBLIC_HOST="$DOMAIN"
            if is_valid_domain "$PANEL_PUBLIC_HOST"; then
                break
            fi
            whiptail --title "Ошибка" --msgbox "Некорректный адрес панели: '${PANEL_PUBLIC_HOST}'\nПример: panel.example.com или 1.2.3.4" 10 70
        done
    fi

    save_install_state
}

ui_get_hardening_info() {
    if [[ "${INSTALL_HARDENING:-false}" != "true" ]]; then
        INSTALL_MODE="simple"
        return 0
    fi

    INSTALL_MODE="super-secure"

    while true; do
        NEW_USER=$(whiptail --title "Новый sudo-пользователь" \
            --inputbox "Имя нового администратора:" \
            10 60 "${NEW_USER:-vpnadmin}" 3>&1 1>&2 2>&3) || exit 0
        if is_valid_username "$NEW_USER"; then
            break
        fi
        whiptail --title "Ошибка" --msgbox \
            "Некорректное имя: '${NEW_USER}'\nДопустимо: строчные буквы, цифры, _ и - (начало: буква или _). Макс. 32 символа." \
            12 60
    done

    while true; do
        local _pass
        _pass=$(whiptail --title "Пароль администратора" \
            --passwordbox "Пароль для ${NEW_USER} (мин. 12 символов, пусто = автогенерация):" \
            10 60 3>&1 1>&2 2>&3) || exit 0
        if [[ -z "${_pass:-}" ]]; then
            [[ -z "${NEW_PASS:-}" ]] && NEW_PASS=$(generate_strong_secret)
            break
        elif (( ${#_pass} >= 12 )); then
            NEW_PASS="$_pass"
            break
        fi
        whiptail --title "Ошибка" --msgbox "Пароль слишком короткий. Минимум 12 символов." 10 60
    done

    while true; do
        SSH_PORT=$(whiptail --title "Порт SSH" \
            --inputbox "Новый порт SSH (1-65535, текущий: ${SSH_PORT:-22}):" \
            10 60 "${SSH_PORT:-22}" 3>&1 1>&2 2>&3) || exit 0
        if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )); then
            # Для нового SSH порта проверяем, что он реально свободен уже на этапе ввода.
            # Порт 22 разрешаем, так как обычно его занимает текущий sshd.
            if ! check_port_free "$SSH_PORT" && ! port_in_use_by_pattern "$SSH_PORT" "sshd" tcp; then
                whiptail --title "Порт занят" --msgbox \
                    "Порт ${SSH_PORT} уже занят другим сервисом. Выберите другой SSH-порт." \
                    10 70
                continue
            fi
            break
        fi
        whiptail --title "Ошибка" --msgbox "Некорректный порт: '${SSH_PORT}'. Диапазон: 1-65535." 10 60
    done

    save_install_state
}

ui_get_panel_exposure_info() {
    [[ "${INSTALL_XUI:-false}" == "true" ]] || return 0

    if [[ "${INSTALL_HARDENING:-false}" == "true" ]]; then
        EXPOSE_PANEL_PUBLIC="false"
        whiptail --title "Публикация панели 3x-ui" --msgbox \
            "Hardening включен: порт панели будет закрыт снаружи.\nИспользуйте SSH-туннель для доступа к 3x-ui." \
            11 72
        save_install_state
        return 0
    fi

    if whiptail --title "Публикация панели 3x-ui" --yesno \
        "Открыть порт панели 3x-ui наружу?\n\nYes: панель будет доступна из интернета.\nNo: порт закрыт, доступ только через SSH-туннель." \
        13 74; then
        EXPOSE_PANEL_PUBLIC="true"
    else
        EXPOSE_PANEL_PUBLIC="false"
    fi
    save_install_state
}

ui_get_ports() {
    local _labels=()
    local _vars=()
    local _defaults=()

    [[ "${INSTALL_XUI:-false}" == "true" ]] && {
        _labels+=("Порт панели 3x-ui:")
        _vars+=(PORT_XUI_PANEL)
        _defaults+=("${PORT_XUI_PANEL:-2053}")
        _labels+=("Порт VLESS Reality:")
        _vars+=(PORT_XUI_REALITY)
        _defaults+=("${PORT_XUI_REALITY:-443}")
    }
    [[ "${INSTALL_OPENVPN:-false}" == "true" ]] && {
        _labels+=("Порт OpenVPN (UDP):")
        _vars+=(PORT_OPENVPN)
        _defaults+=("${PORT_OPENVPN:-1194}")
    }
    [[ "${INSTALL_OPENCONNECT:-false}" == "true" ]] && {
        _labels+=("Порт OpenConnect:")
        _vars+=(PORT_OPENCONNECT)
        _defaults+=("${PORT_OPENCONNECT:-4443}")
    }
    [[ "${INSTALL_AMNEZIA:-false}" == "true" ]] && {
        _labels+=("Порт AmneziaWG (UDP):")
        _vars+=(PORT_AMNEZIA)
        _defaults+=("${PORT_AMNEZIA:-39442}")
    }
    [[ "${INSTALL_DUMBPROXY:-false}" == "true" ]] && {
        _labels+=("Порт Dumbproxy (TCP):")
        _vars+=(PORT_DUMBPROXY)
        _defaults+=("${PORT_DUMBPROXY:-8080}")
    }
    [[ "${INSTALL_MTPROXY:-false}" == "true" ]] && {
        _labels+=("Порт MTProto (TCP):")
        _vars+=(PORT_MTPROXY)
        _defaults+=("${PORT_MTPROXY:-8443}")
    }

    [[ ${#_vars[@]} -eq 0 ]] && return 0

    while true; do
        # Собираем порты по одному через inputbox (--form не поддерживается надёжно в whiptail)
        local _values=()
        local _cancelled=false
        local i
        for (( i=0; i<${#_labels[@]}; i++ )); do
            local _val
            if ! _val=$(whiptail --title "Настройка портов ($(( i+1 ))/${#_labels[@]})" \
                --inputbox "${_labels[$i]}" \
                8 52 "${_defaults[$i]}" 3>&1 1>&2 2>&3); then
                _cancelled=true
                break
            fi
            _values+=("$_val")
        done

        if [[ "$_cancelled" == "true" ]]; then
            exit 0
        fi

        local _ok=true
        local _err=""
        local j
        # Validate each port number
        for (( j=0; j<${#_vars[@]}; j++ )); do
            local p="${_values[$j]:-}"
            if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
                _ok=false
                _err="Некорректный порт '${p}' для ${_labels[$j]}\nДиапазон: 1-65535."
                break
            fi
        done

        # Check for duplicates among service ports
        if [[ "$_ok" == "true" ]]; then
            declare -A _port_seen=()
            for (( j=0; j<${#_vars[@]}; j++ )); do
                local p="${_values[$j]}"
                if [[ -n "${_port_seen[$p]+x}" ]]; then
                    _ok=false
                    _err="Конфликт: порт $p используется для '${_port_seen[$p]}' и '${_labels[$j]}'.\nКаждый сервис должен иметь уникальный порт."
                    break
                fi
                _port_seen[$p]="${_labels[$j]}"
            done
        fi

        # Check collision with SSH port
        if [[ "$_ok" == "true" ]]; then
            for (( j=0; j<${#_vars[@]}; j++ )); do
                if [[ "${_values[$j]}" == "${SSH_PORT:-22}" ]]; then
                    _ok=false
                    _err="Конфликт: порт ${_values[$j]} (${_labels[$j]}) совпадает с портом SSH (${SSH_PORT:-22})."
                    break
                fi
            done
        fi

        # Check if selected service ports are occupied by running processes
        if [[ "$_ok" == "true" ]]; then
            for (( j=0; j<${#_vars[@]}; j++ )); do
                local p="${_values[$j]}"
                if ! check_port_free "$p" && ! ui_port_reusable_for_selected_service "${_vars[$j]}" "$p"; then
                    _ok=false
                    _err="Порт ${p} (${_labels[$j]}) уже занят запущенным сервисом.\nВыберите другой порт."
                    break
                fi
            done
        fi

        if [[ "$_ok" == "true" ]]; then
            for (( j=0; j<${#_vars[@]}; j++ )); do
                printf -v "${_vars[$j]}" '%s' "${_values[$j]}"
            done
            save_install_state
            return 0
        fi

        whiptail --title "Ошибка" --msgbox "$_err" 10 65
        # Preserve user-entered values as new defaults for retry
        for (( j=0; j<${#_vars[@]}; j++ )); do
            [[ -n "${_values[$j]:-}" ]] && _defaults[$j]="${_values[$j]}"
        done
    done
}

ui_get_mtproto_domain() {
    [[ "${INSTALL_MTPROXY:-false}" == "true" ]] || return 0

    local _default="${MTPROXY_DOMAIN:-}"
    [[ -z "$_default" ]] && _default="www.google.com"

    while true; do
        local _domain
        if ! _domain=$(whiptail --title "MTProto Fake-TLS" \
            --inputbox "Домен для маскировки Fake-TLS.\nДолжен быть популярным внешним сайтом — НЕ доменом этого сервера." \
            10 70 "$_default" 3>&1 1>&2 2>&3); then
            exit 0
        fi

        if ! is_valid_domain "$_domain"; then
            whiptail --title "Ошибка" --msgbox "Некорректный домен: '${_domain}'." 10 60
            _default="$_domain"
            continue
        fi

        if [[ -n "${DOMAIN:-}" && "$_domain" == "$DOMAIN" ]]; then
            if ! whiptail --title "Предупреждение" --yesno \
                "Домен маскировки совпадает с доменом этого сервера (${DOMAIN}).\nЭто создаёт circular-probe и может выдать прокси.\n\nВсё равно продолжить с этим доменом?" \
                12 70; then
                _default="$_domain"
                continue
            fi
        fi

        MTPROXY_DOMAIN="$_domain"
        save_install_state
        return 0
    done
}

ui_get_tproxy_info() {
    [[ "${INSTALL_TPROXY:-false}" == "true" ]] || return 0

    local _default_domain="${TPROXY_DOMAIN:-${DOMAIN:-}}"
    local _default_sni="${TPROXY_FAKETLS_SNI:-magic-ball.duckdns.org}"

    while true; do
        local _domain
        if ! _domain=$(whiptail --title "Telegram WebProxy (Desktop) — Домен" \
            --inputbox "Введите домен для Telegram WebProxy (Desktop).\n\nНАЗНАЧЕНИЕ: Реальный домен, указывающий (DNS A-запись) на IP этого сервера.\nCaddy использует его для выпуска валидного TLS-сертификата.\n\nПример: proxy.example.com" \
            14 75 "$_default_domain" 3>&1 1>&2 2>&3); then
            exit 0
        fi

        if ! is_valid_domain "$_domain"; then
            whiptail --title "Ошибка" --msgbox "Некорректный домен: '${_domain}'." 10 60
            _default_domain="$_domain"
            continue
        fi

        TPROXY_DOMAIN="$_domain"
        break
    done

    while true; do
        local _sni
        if ! _sni=$(whiptail --title "Telegram Mobile — Маскировочный Fake-TLS SNI" \
            --inputbox "Введите маскировочный SNI для Telegram Mobile (Fake-TLS).\n\nНАЗНАЧЕНИЕ: Внешний домен для маскировки мобильного MTProto рукопожатия.\n\nВНИМАНИЕ: Не должен совпадать с доменом WebProxy (${TPROXY_DOMAIN}), чтобы HAProxy на 443 порту разделял трафик без коллизий.\n\nПример: magic-ball.duckdns.org или gateway.icloud.com" \
            16 75 "$_default_sni" 3>&1 1>&2 2>&3); then
            exit 0
        fi

        if ! is_valid_domain "$_sni"; then
            whiptail --title "Ошибка" --msgbox "Некорректный SNI: '${_sni}'." 10 60
            _default_sni="$_sni"
            continue
        fi

        if [[ "$_sni" == "$TPROXY_DOMAIN" ]]; then
            whiptail --title "Ошибка коллизии" --msgbox "Маскировочный SNI не может совпадать с доменом WebProxy (${TPROXY_DOMAIN}).\nHAProxy не сможет разделить входящие TLS-соединения на порту 443." 10 70
            _default_sni="$_sni"
            continue
        fi

        TPROXY_FAKETLS_SNI="$_sni"
        break
    done

    save_install_state
    return 0
}

ui_confirm_install() {
    if whiptail --title "Aegis Gateway" --yesno "Начать установку выбранных компонентов?" 10 60; then
        return 0
    else
        exit 0
    fi
}

ui_ask_reinstall() {
    local service_name="$1"
    if whiptail --title "Сервис уже установлен" --yesno "Обнаружен уже установленный $service_name. Переустановить и настроить заново?\n\n(Выбор 'No' пропустит этот компонент)" 12 60; then
        return 0 # Reinstall
    else
        return 1 # Skip
    fi
}

ui_final_report() {
    local report=""
    local plain_report=""

    # Формируем отчет
    report="${BOLD}Aegis Gateway: Установка завершена успешно!${NC}\n"
    report="${report}==============================================\n\n"

    report="${report}${BLUE}${BOLD}--- ПАРАМЕТРЫ УСТАНОВКИ (ВВОД ПОЛЬЗОВАТЕЛЯ) ---${NC}\n"
    report="${report}Домен/IP: ${DOMAIN}\n"
    report="${report}Email: ${EMAIL:-не задан}\n"
    report="${report}VPN пользователь: ${VPN_USER:-vpnuser}\n"
    report="${report}Исключения маршрутов: ${VPN_EXCLUDE_ROUTES:-не заданы}\n"
    report="${report}Hardening: ${INSTALL_HARDENING:-false}\n"
    report="${report}Режим: ${INSTALL_MODE:-simple}\n"
    report="${report}Публикация панели: ${EXPOSE_PANEL_PUBLIC:-false}\n"
    report="${report}Адрес панели: ${PANEL_PUBLIC_HOST:-$DOMAIN}\n"
    report="${report}Порт SSH: ${SSH_PORT:-22}\n"
    report="${report}Порт панели 3x-ui: ${PORT_XUI_PANEL:-2053}\n"
    report="${report}Порт VLESS Reality: ${PORT_XUI_REALITY:-443}\n"
    report="${report}Порт OpenVPN: ${PORT_OPENVPN:-1194}\n"
    report="${report}Порт OpenConnect: ${PORT_OPENCONNECT:-4443}\n"
    report="${report}Порт AmneziaWG: ${PORT_AMNEZIA:-39442}\n"
    report="${report}Порт Dumbproxy: ${PORT_DUMBPROXY:-8080}\n"
    if [[ "$INSTALL_MTPROXY" == "true" ]]; then
        report="${report}Порт MTProto: ${PORT_MTPROXY:-8443}\n"
    fi
    if [[ "$INSTALL_TPROXY" == "true" ]]; then
        report="${report}Порт Telegram Ingress: 443 (WebProxy & Fake-TLS)\n"
    fi
    report="${report}\n"

    report="${report}${BLUE}${BOLD}--- ОБЩИЕ ДАННЫЕ СЕРВЕРА ---${NC}\n"
    if [[ "${INSTALL_MODE:-}" == "super-secure" ]]; then
        report="${report}SSH Пользователь: ${NEW_USER:-root}\n"
        report="${report}SSH Пароль: ${NEW_PASS:-unchanged}\n"
        report="${report}SSH Порт: ${SSH_PORT:-22}\n"
    fi
    report="${report}\n"

    if [[ "$INSTALL_XUI" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- 3x-ui (Xray Panel) ---${NC}\n"
        report="${report}Панель управления: http://${PANEL_PUBLIC_HOST:-$DOMAIN}:${PORT_XUI_PANEL:-2053}\n"
        report="${report}Публичный доступ: ${EXPOSE_PANEL_PUBLIC:-false}\n"
        report="${report}Логин: ${PANEL_ADMIN_USER:-admin}\n"
        report="${report}Пароль: ${PANEL_ADMIN_PASS:-admin}\n"
        report="${report}VLESS Reality порт: ${PORT_XUI_REALITY:-443}\n"
        if [[ "${EXPOSE_PANEL_PUBLIC:-false}" != "true" ]]; then
            local tunnel_user tunnel_port
            tunnel_user="${NEW_USER:-root}"
            tunnel_port="${SSH_PORT:-22}"
            report="${report}SSH-туннель (пример):\n"
            report="${report}  ssh -N -L ${PORT_XUI_PANEL:-2053}:127.0.0.1:${PORT_XUI_PANEL:-2053} ${tunnel_user}@${DOMAIN} -p ${tunnel_port}\n"
        fi
        report="${report}\n"
    elif [[ "$INSTALL_XUI" == "skipped" ]]; then
        report="${report}${YELLOW}--- 3x-ui (Пропущено) ---${NC}\n\n"
    fi

    if [[ "$INSTALL_OPENVPN" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- OpenVPN ---${NC}\n"
        report="${report}Протокол/Порт: UDP / ${PORT_OPENVPN:-1194}\n"
        report="${report}Пользователь: ${VPN_USER:-vpnuser}\n"
        report="${report}Файл конфигурации (.ovpn): /etc/openvpn/${VPN_USER:-vpnuser}.ovpn\n"
        if [[ -n "${NEW_USER:-}" ]] && [[ -d "/home/${NEW_USER}" ]]; then
            report="${report}Доступная копия (SSH): /home/${NEW_USER}/${VPN_USER:-vpnuser}.ovpn\n"
        fi
        report="${report}\n"
    elif [[ "$INSTALL_OPENVPN" == "skipped" ]]; then
        report="${report}${YELLOW}--- OpenVPN (Пропущено) ---${NC}\n\n"
    fi

    if [[ "$INSTALL_OPENCONNECT" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- OpenConnect (Cisco AnyConnect) ---${NC}\n"
        report="${report}Сервер: ${DOMAIN}:${PORT_OPENCONNECT:-4443}\n"
        report="${report}Пользователь: ${VPN_USER:-vpnuser}\n"
        report="${report}Пароль: ${VPN_PASS}\n\n"
    elif [[ "$INSTALL_OPENCONNECT" == "skipped" ]]; then
        report="${report}${YELLOW}--- OpenConnect (Пропущено) ---${NC}\n\n"
    fi

    if [[ "$INSTALL_AMNEZIA" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- AmneziaWG ---${NC}\n"
        report="${report}Endpoint: ${DOMAIN}:${PORT_AMNEZIA:-39442}/udp\n"
        report="${report}Конфиг клиента: /etc/amnezia/amneziawg/clients/amnezia-client1.conf\n"
        if [[ -n "${NEW_USER:-}" ]] && [[ -d "/home/${NEW_USER}" ]]; then
            report="${report}Копия (SSH): /home/${NEW_USER}/amnezia_client1.conf\n"
        fi
        report="${report}\n"
    elif [[ "$INSTALL_AMNEZIA" == "skipped" ]]; then
        report="${report}${YELLOW}--- AmneziaWG (Пропущено) ---${NC}\n\n"
    fi

    if [[ "$INSTALL_DUMBPROXY" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- Dumbproxy (HTTP/HTTPS Proxy) ---${NC}\n"
        report="${report}Адрес: ${DOMAIN}:${PORT_DUMBPROXY:-8080}\n"
        report="${report}Пользователь: ${VPN_USER:-vpnuser}\n"
        report="${report}Пароль: ${VPN_PASS}\n\n"
    elif [[ "$INSTALL_DUMBPROXY" == "skipped" ]]; then
        report="${report}${YELLOW}--- Dumbproxy (Пропущено) ---${NC}\n\n"
    fi

    if [[ "$INSTALL_TPROXY" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- Telegram Proxy (443 Ingress) ---${NC}\n"
        report="${report}1. Telegram WebProxy (Desktop): https://${TPROXY_DOMAIN:-${DOMAIN:-localhost}}:443\n"
        report="${report}   Секрет: ${TPROXY_SECRET:-}\n"
        local _faketls_sni="${TPROXY_FAKETLS_SNI:-magic-ball.duckdns.org}"
        local _hex_sni _ee_secret _tg_link
        _hex_sni=$(python3 -c "import sys; print(sys.argv[1].encode().hex())" "$_faketls_sni" 2>/dev/null || true)
        _ee_secret="ee${TPROXY_SECRET:-}${_hex_sni}"
        if [[ -n "${DOMAIN:-}" ]]; then
            _tg_link=$(mtproto_proxy_link_tg "$DOMAIN" "443" "$_ee_secret")
            report="${report}2. Telegram Mobile (Fake-TLS): ${_tg_link}\n"
            report="${report}   Маскировочный SNI: ${_faketls_sni}\n\n"
        else
            report="${report}${YELLOW}Ссылка Telegram Mobile недоступна: DOMAIN не задан.${NC}\n\n"
        fi
    elif [[ "$INSTALL_MTPROXY" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- MTProto (Telegram Proxy) ---${NC}\n"
        report="${report}Сервер: ${DOMAIN}:${PORT_MTPROXY:-8443}\n"
        report="${report}Секрет: ${MTPROXY_SECRET}\n"
        if [[ -n "${DOMAIN:-}" ]]; then
            report="${report}Ссылка Telegram: $(mtproto_proxy_link_tg "$DOMAIN" "${PORT_MTPROXY:-8443}" "$MTPROXY_SECRET")\n"
            report="${report}Эквивалент: $(mtproto_proxy_link_https "$DOMAIN" "${PORT_MTPROXY:-8443}" "$MTPROXY_SECRET")\n\n"
        else
            report="${report}${YELLOW}Ссылка Telegram недоступна: DOMAIN не задан.${NC}\n\n"
        fi
    elif [[ "$INSTALL_TPROXY" == "skipped" || "$INSTALL_MTPROXY" == "skipped" ]]; then
        report="${report}${YELLOW}--- Telegram Proxy (Пропущено) ---${NC}\n\n"
    fi

    if [[ "$INSTALL_WARP_TELEGRAM" == "true" ]]; then
        report="${report}${BLUE}${BOLD}--- Telegram WARP Egress Routing ---${NC}\n"
        report="${report}Статус: Установлен нативно через wgcf (wg-quick@warp)\n"
        report="${report}NAT/Split-Tunnel: Настроен для подсетей Telegram\n"
        report="${report}Влияние: Локальные VPN-клиенты маршрутизируют трафик Telegram через выделенный интерфейс\n\n"
    elif [[ "$INSTALL_WARP_TELEGRAM" == "skipped" ]]; then
        report="${report}${YELLOW}--- Telegram WARP (Пропущено) ---${NC}\n\n"
    fi

    report="${report}${GREEN}${BOLD}Все пароли сохранены в файле состояния: /root/.aegis-vpn.state${NC}\n"

    # Создаем чистую версию без ANSI кодов для whiptail
    plain_report=$(printf '%s' "$report" | sed 's/\x1b\[[0-9;]*m//g')

    local _rows _cols
    _rows=$(( $(tput lines 2>/dev/null || echo 24) - 4 ))
    _cols=$(( $(tput cols  2>/dev/null || echo 80) - 4 ))
    (( _rows < 20 )) && _rows=20
    (( _cols < 70 )) && _cols=70
    whiptail --title "Aegis Gateway - Итоги" --scrolltext --msgbox "$plain_report" "$_rows" "$_cols"
    clear
    printf '%b' "$report"
}
