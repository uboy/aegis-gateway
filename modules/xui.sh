#!/usr/bin/env bash

# Подключаем API библиотеку внутри модуля если она еще не подключена
source "${SCRIPT_DIR}/lib/xui_api.sh"

module_xui_install() {
    [[ "$INSTALL_XUI" == "true" ]] || return 0
    
    PANEL_DIR="${PANEL_DIR:-/opt/3x-ui}"

    # Детекция существующей установки
    if docker ps -a --format '{{.Names}}' | grep -q "^3x-ui$"; then
        if ! ui_ask_reinstall "3x-ui Panel"; then
            log "Пропуск установки 3x-ui по желанию пользователя."
            INSTALL_XUI="skipped"
            return 0
        fi
        log "Очистка старой установки 3x-ui..."
        [[ -n "${PANEL_DIR:-}" ]] || { error "PANEL_DIR не задан"; return 1; }
        ( cd "$PANEL_DIR" && docker compose down -v 2>/dev/null ) || true
        rm -rf "$PANEL_DIR"
    fi

    log "Установка 3x-ui (через Docker)..."
    mkdir -p "$PANEL_DIR/db" "$PANEL_DIR/cert"

    # Generate credentials BEFORE writing docker-compose to avoid admin:admin window
    local new_user new_pass
    new_user="${PANEL_ADMIN_USER:-admin_$(generate_random_fixed 5 'a-z0-9' true)}"
    new_pass="${PANEL_ADMIN_PASS:-$(generate_strong_secret)}"
    PANEL_ADMIN_USER="$new_user"
    PANEL_ADMIN_PASS="$new_pass"

    # Возвращаем шаблонную схему 3x-ui (host network), чтобы не ломать
    # совместимость и текущую модель инбаундов.
    cat > "${PANEL_DIR}/docker-compose.yml" <<'EOF'
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert
    restart: unless-stopped
    network_mode: host
EOF

    ( cd "$PANEL_DIR" && docker compose up -d )

    local target_panel_port="${PORT_XUI_PANEL:-2053}"
    local default_panel_port="2053"
    local panel_ready=false

    log "Ожидание готовности панели на порту ${target_panel_port} (макс. 120 сек)..."
    local attempts=0
    while (( attempts < 60 )); do
        if curl -sf --max-time 2 "http://127.0.0.1:${target_panel_port}/" >/dev/null 2>&1; then
            panel_ready=true
            break
        fi
        local cstate
        cstate=$(docker inspect --format '{{.State.Status}}' 3x-ui 2>/dev/null || true)
        if [[ "$cstate" == "exited" || "$cstate" == "dead" ]]; then
            error "Контейнер 3x-ui упал (State: ${cstate}). Логи:"
            docker logs 3x-ui --tail=30
            return 1
        fi
        (( attempts++ )) || true
        [[ $(( attempts % 10 )) -eq 0 ]] && log "Ожидание... (попытка ${attempts}/60)"
        sleep 2
    done

    if [[ "$panel_ready" != "true" && "$target_panel_port" != "$default_panel_port" ]]; then
        log "Панель не отвечает на ${target_panel_port}; пробуем дефолтный порт ${default_panel_port}..."
        if curl -sf --max-time 3 "http://127.0.0.1:${default_panel_port}/" >/dev/null 2>&1; then
            log "Переключение порта панели 3x-ui на ${target_panel_port}..."
            if docker exec 3x-ui x-ui setting -port "${target_panel_port}" >/dev/null 2>&1 \
               || docker exec 3x-ui /usr/local/x-ui/x-ui setting -port "${target_panel_port}" >/dev/null 2>&1; then
                docker restart 3x-ui >/dev/null 2>&1 || true
                attempts=0
                while (( attempts < 60 )); do
                    if curl -sf --max-time 2 "http://127.0.0.1:${target_panel_port}/" >/dev/null 2>&1; then
                        panel_ready=true
                        break
                    fi
                    (( attempts++ )) || true
                    sleep 2
                done
            else
                warn "Не удалось автоматически применить порт панели ${target_panel_port}; панель осталась на ${default_panel_port}."
            fi
        fi
    fi

    if [[ "$panel_ready" != "true" ]]; then
        error "Панель 3x-ui не ответила на порту ${target_panel_port}. Логи:"
        docker logs 3x-ui --tail=30
        if [[ "$target_panel_port" != "$default_panel_port" ]]; then
            warn "Проверьте доступность дефолтного порта панели: ${default_panel_port}"
        fi
        return 1
    fi
}

module_xui_configure() {
    [[ "$INSTALL_XUI" == "true" ]] || return 0

    log "Настройка параметров 3x-ui через API..."
    local panel_url="http://127.0.0.1:${PORT_XUI_PANEL:-2053}"

    # Сначала пробуем уже сгенерированные учётные данные (повторный запуск скрипта)
    if ! xui_api_login "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS" "$panel_url"; then
        # Первый запуск — панель стартует с дефолтными admin/admin
        log "Вход с дефолтными учетными данными (admin/admin)..."
        if ! xui_api_login "admin" "admin" "$panel_url"; then
            error "Не удалось войти в панель ни с предустановленными, ни с дефолтными учетными данными."
            return 1
        fi
        log "Замена дефолтных учетных данных на сгенерированные..."
        if ! xui_api_update_user "admin" "admin" "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS" "$panel_url"; then
            error "Не удалось обновить учетные данные панели."
            return 1
        fi
        # Проверяем новые данные
        if ! xui_api_login "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS" "$panel_url"; then
            error "Новые учетные данные не приняты панелью."
            return 1
        fi
    fi
    success "Аутентификация в панели успешна (пользователь: $PANEL_ADMIN_USER)."
    save_install_state

    if [[ "${AUTO_CREATE_INBOUND:-true}" == "true" ]]; then
        log "Создание автоматического VLESS Reality инбаунда..."
        local client_id
        client_id=$(generate_uuid)

        # Генерируем валидный X25519 private key для Reality.
        local x25519_out reality_priv_key sid
        x25519_out=$(docker exec 3x-ui sh -lc 'xray x25519 2>/dev/null || /usr/local/x-ui/bin/xray x25519 2>/dev/null' 2>/dev/null || true)
        reality_priv_key=$(printf '%s' "$x25519_out" | sed -n 's/.*Private key:[[:space:]]*//p' | head -n1)
        if [[ -z "${reality_priv_key:-}" ]]; then
            warn "Не удалось сгенерировать валидный Reality privateKey через xray x25519. Авто-создание inbound пропущено."
            return 0
        fi
        sid=$(generate_random_fixed 8 '0-9a-f' true)

        local settings stream_settings reality_dest reality_server_name reality_flow
        # Compatibility-first defaults (can be overridden via env):
        # - REALITY_DEST (e.g. google.com:443, www.cloudflare.com:443)
        # - REALITY_SERVER_NAME (SNI)
        # - REALITY_FLOW (e.g. "", xtls-rprx-vision)
        reality_dest="${REALITY_DEST:-google.com:443}"
        reality_server_name="${REALITY_SERVER_NAME:-google.com}"
        # xtls-rprx-vision — рекомендуемый flow для Reality+TCP: нативный TLS внутри туннеля,
        # лучшая пропускная способность и стабильность по сравнению с пустым flow.
        reality_flow="${REALITY_FLOW:-xtls-rprx-vision}"
        settings=$(jq -cn \
            --arg id "$client_id" \
            --arg email "${VPN_USER:-vpn}@${DOMAIN}" \
            --arg flow "$reality_flow" \
            '{decryption:"none",clients:[{id:$id,flow:$flow,email:$email,totalGB:0,expiryTime:0,enable:true}]}')
        # shortIds содержит сгенерированный ID и пустую строку "" для совместимости
        # со старыми клиентами, которые не передают shortId при подключении.
        stream_settings=$(jq -cn \
            --arg pk "$reality_priv_key" \
            --arg sid "$sid" \
            --arg rd "$reality_dest" \
            --arg rsn "$reality_server_name" \
            '{network:"tcp",security:"reality",realitySettings:{show:false,dest:$rd,serverNames:[$rsn],privateKey:$pk,shortIds:[$sid,""]}}')


        local response
        if xui_api_add_inbound "Aegis_VLESS_Reality" "${PORT_XUI_REALITY:-443}" "vless" "$settings" "$stream_settings" "$panel_url"; then
            success "Инбаунд Aegis_VLESS_Reality создан на порту ${PORT_XUI_REALITY:-443}."
        else
            warn "Не удалось создать инбаунд через API (возможно, он уже существует или ошибка в параметрах). Проверьте панель вручную."
        fi
    fi
}
