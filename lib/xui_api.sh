#!/usr/bin/env bash

# Библиотека для работы с API 3x-ui

PANEL_COOKIE_FILE=""
_XUI_COOKIE_TRAP_SET=0

_xui_cookie_init() {
    PANEL_COOKIE_FILE="$(mktemp -p /root .3xui-cookie.XXXXXX)"
    chmod 600 "$PANEL_COOKIE_FILE"
    if (( _XUI_COOKIE_TRAP_SET == 0 )); then
        # Сохраняем существующий EXIT trap и добавляем cleanup к нему,
        # не заменяя — иначе on_exit из install.sh (save_install_state) потеряется.
        local _prev_trap
        _prev_trap=$(trap -p EXIT 2>/dev/null | sed -E "s/trap -- '(.*)' EXIT/\\1/")
        if [[ -n "$_prev_trap" ]]; then
            # shellcheck disable=SC2064
            trap "${_prev_trap}; _xui_cookie_cleanup" EXIT
        else
            trap '_xui_cookie_cleanup' EXIT
        fi
        _XUI_COOKIE_TRAP_SET=1
    fi
}

_xui_cookie_cleanup() {
    [[ -n "${PANEL_COOKIE_FILE:-}" && -f "$PANEL_COOKIE_FILE" ]] && rm -f "$PANEL_COOKIE_FILE"
}

xui_api_login() {
    local username="$1"
    local password="$2"
    local origin="${3:-http://127.0.0.1:2053}"
    local base_path="${4:-/}"

    log "Попытка входа в API 3x-ui (пользователь: $username)..."

    _xui_cookie_init

    local response
    response=$(curl -sS --max-time 10 --noproxy '*' \
      -c "$PANEL_COOKIE_FILE" -b "$PANEL_COOKIE_FILE" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=${username}" \
      --data-urlencode "password=${password}" \
      "${origin}${base_path}login" || true)

    if [[ "$response" == *'"success":true'* ]]; then
        success "Вход в API выполнен."
        return 0
    else
        error "Ошибка входа в API. Ответ: $response"
        return 1
    fi
}

xui_api_update_user() {
    local old_user="$1"
    local old_pass="$2"
    local new_user="$3"
    local new_pass="$4"
    local origin="${5:-http://127.0.0.1:2053}"
    local base_path="${6:-/}"

    log "Обновление учетных данных панели..."
    
    local response
    response=$(curl -sS --max-time 10 --noproxy '*' \
      -c "$PANEL_COOKIE_FILE" -b "$PANEL_COOKIE_FILE" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "oldUsername=${old_user}" \
      --data-urlencode "oldPassword=${old_pass}" \
      --data-urlencode "newUsername=${new_user}" \
      --data-urlencode "newPassword=${new_pass}" \
      "${origin}${base_path}panel/setting/updateUser" || true)
    if [[ "$response" == *'"success":true'* ]]; then
        return 0
    fi
    error "Ошибка updateUser API (${origin}${base_path}panel/setting/updateUser). Ответ: $response"
    return 1
}

xui_api_add_inbound() {
    local remark="$1"
    local port="$2"
    local protocol="${3:-vless}"
    local settings="$4"
    local stream_settings="$5"
    local origin="${6:-http://127.0.0.1:2053}"
    local base_path="${7:-/}"

    log "Создание входящего подключения (inbound) $remark на порту $port..."
    
    local response
    response=$(curl -sS --max-time 12 --noproxy '*' \
      -c "$PANEL_COOKIE_FILE" -b "$PANEL_COOKIE_FILE" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "remark=${remark}" \
      --data-urlencode "port=${port}" \
      --data-urlencode "protocol=${protocol}" \
      --data-urlencode "settings=${settings}" \
      --data-urlencode "streamSettings=${stream_settings}" \
      --data-urlencode "enable=true" \
      --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic"]}' \
      -X POST \
      "${origin}${base_path}panel/api/inbounds/add" || true)
    if [[ "$response" == *'"success":true'* ]]; then
        return 0
    fi
    error "Ошибка add_inbound API (${origin}${base_path}panel/api/inbounds/add). Ответ: $response"
    return 1
}
