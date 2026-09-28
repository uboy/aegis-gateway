#!/usr/bin/env bash

module_dumbproxy_install() {
    [[ "$INSTALL_DUMBPROXY" == "true" ]] || return 0

    local dp_port="${PORT_DUMBPROXY:-8080}"
    local dp_user="${VPN_USER:-vpnuser}"
    local dp_pass="${VPN_PASS}"

    # Detect existing installation
    if systemctl is-active --quiet dumbproxy 2>/dev/null || [[ -x /usr/local/bin/dumbproxy ]]; then
        if ! ui_ask_reinstall "dumbproxy"; then
            log "Пропуск установки dumbproxy."
            INSTALL_DUMBPROXY="skipped"
            return 0
        fi
        systemctl stop dumbproxy 2>/dev/null || true
        systemctl disable dumbproxy 2>/dev/null || true
        rm -f /usr/local/bin/dumbproxy /etc/systemd/system/dumbproxy.service
        rm -rf /etc/dumbproxy
    fi

    log "Установка dumbproxy..."

    # Determine architecture
    local go_arch
    case "$(dpkg --print-architecture)" in
        amd64)  go_arch="amd64" ;;
        arm64)  go_arch="arm64" ;;
        *)      error "Неподдерживаемая архитектура: $(dpkg --print-architecture)"; return 1 ;;
    esac

    # Get latest release download URL via GitHub API
    log "Получение последней версии dumbproxy..."
    local api_response download_url
    api_response=$(curl -sS --max-time 15 \
        "https://api.github.com/repos/SenseUnit/dumbproxy/releases/latest" 2>&1) || true

    # Detect API-level errors (rate limit, auth, etc.)
    if echo "$api_response" | jq -e '.message' &>/dev/null 2>&1; then
        error "GitHub API вернул ошибку: $(echo "$api_response" | jq -r '.message')"
        return 1
    fi

    # Assets are plain binaries: dumbproxy.linux-amd64 (no tarball)
    download_url=$(echo "$api_response" \
        | jq -r --arg sfx "linux-${go_arch}" \
            '.assets[] | select(.name | endswith($sfx)) | .browser_download_url' \
            2>/dev/null || true)

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        error "Не удалось получить URL загрузки dumbproxy с GitHub API"
        log "Ответ API: $(echo "$api_response" | jq -r '[.assets[].name] | @json' 2>/dev/null || echo "$api_response" | head -c 500)"
        return 1
    fi

    log "Загрузка: ${download_url}"
    curl -fsSL --max-time 60 "$download_url" -o /usr/local/bin/dumbproxy
    chmod 755 /usr/local/bin/dumbproxy

    # Выделенный системный пользователь (убирает предупреждение systemd про nobody)
    if ! id _dumbproxy &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin _dumbproxy
    fi

    # Файл паролей для basicfile auth
    mkdir -p /etc/dumbproxy
    dumbproxy -passwd /etc/dumbproxy/passwd "$dp_user" "$dp_pass"
    chown root:_dumbproxy /etc/dumbproxy/passwd
    chmod 640 /etc/dumbproxy/passwd

    # TLS: использовать существующий Let's Encrypt сертификат если есть.
    # _dumbproxy не имеет доступа к /etc/letsencrypt/archive/ (root:root 700),
    # поэтому копируем сертификаты в /etc/dumbproxy/ с нужными правами.
    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    local tls_args=""
    if [[ -f "$cert_path" && -f "$key_path" ]]; then
        cp "$cert_path" /etc/dumbproxy/fullchain.pem
        cp "$key_path"  /etc/dumbproxy/privkey.pem
        chown root:_dumbproxy /etc/dumbproxy/fullchain.pem /etc/dumbproxy/privkey.pem
        chmod 640 /etc/dumbproxy/fullchain.pem /etc/dumbproxy/privkey.pem
        tls_args="-cert /etc/dumbproxy/fullchain.pem -key /etc/dumbproxy/privkey.pem"
        log "TLS включён (сертификат скопирован из ${cert_path})"

        # Deploy hook: обновляем копию при автопродлении certbot
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/dumbproxy <<'HOOK'
#!/usr/bin/env bash
cert_dir="/etc/letsencrypt/live/${RENEWED_DOMAINS%% *}"
cp "${cert_dir}/fullchain.pem" /etc/dumbproxy/fullchain.pem
cp "${cert_dir}/privkey.pem"   /etc/dumbproxy/privkey.pem
chown root:_dumbproxy /etc/dumbproxy/fullchain.pem /etc/dumbproxy/privkey.pem
chmod 640 /etc/dumbproxy/fullchain.pem /etc/dumbproxy/privkey.pem
systemctl restart dumbproxy
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/dumbproxy
    else
        warn "TLS сертификат не найден — dumbproxy запускается без TLS (HTTP-only)."
    fi

    # Systemd unit
    cat > /etc/systemd/system/dumbproxy.service <<EOF
[Unit]
Description=Dumbproxy HTTP/HTTPS Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/dumbproxy -bind-address :${dp_port} -auth 'basicfile://?path=/etc/dumbproxy/passwd' ${tls_args}
Restart=on-failure
RestartSec=5
User=_dumbproxy
Group=_dumbproxy
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dumbproxy
    systemctl start dumbproxy

    sleep 2
    if ! systemctl is-active --quiet dumbproxy; then
        error "dumbproxy не запустился. Журнал:"
        journalctl -u dumbproxy --no-pager | tail -15
        return 1
    fi

    firewall_allow "${dp_port}" tcp
    success "dumbproxy запущен на порту ${dp_port} (пользователь: ${dp_user})."
}
