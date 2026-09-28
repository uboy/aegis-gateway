#!/usr/bin/env bash

module_openconnect_install() {
    [[ "$INSTALL_OPENCONNECT" == "true" ]] || return 0
    
    # 1. Глубокая очистка при переустановке
    if dpkg -l ocserv &>/dev/null; then
        if ! ui_ask_reinstall "OpenConnect (ocserv)"; then
            log "Пропуск установки OpenConnect."
            INSTALL_OPENCONNECT="skipped"
            return 0
        fi
        log "Полное удаление старой установки ocserv..."
        systemctl stop ocserv 2>/dev/null || true
        # Удаляем директории ДО purge, чтобы dpkg не жаловался на "not empty"
        rm -rf /etc/ocserv
        rm -rf /run/ocserv
        apt-get purge -y ocserv || true
    fi

    log "Установка OpenConnect (ocserv) нативно..."
    apt-get update && apt-get install -y ocserv
    
    # 2. Подготовка сертификатов
    local cert_dir="/etc/letsencrypt/live/$DOMAIN"
    local cert_path="${cert_dir}/fullchain.pem"
    local key_path="${cert_dir}/privkey.pem"
    
    mkdir -p "$cert_dir"
    if [[ ! -f "$cert_path" ]]; then
        warn "Сертификаты не найдены. Генерируем временные..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$key_path" -out "$cert_path" \
            -subj "/CN=$DOMAIN"
        chmod 600 "$key_path"
    fi

    # 3. Генерация ПРАВИЛЬНОГО конфига (исправлено для Ubuntu 24.04)
    log "Настройка конфигурации ocserv..."
    cat > /etc/ocserv/ocserv.conf <<EOF
# Способ аутентификации
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
log-level = 3

# Сетевые настройки
tcp-port = ${PORT_OPENCONNECT:-4443}
udp-port = ${PORT_OPENCONNECT:-4443}
device = vpns
socket-file = /run/ocserv.socket
run-as-user = ocserv
run-as-group = ocserv

# Сертификаты
server-cert = $cert_path
server-key = $key_path

# Лимиты и тайм-ауты
isolate-workers = true
max-clients = 64
max-same-clients = 9
keepalive = 20
dpd = 300
mobile-dpd = 1800
switch-to-tcp-timeout = 5
try-mtu-discovery = true
mtu = 1200
idle-timeout = 86400
mobile-idle-timeout = 86400
compression = false
no-compress-limit = 256
cookie-timeout = 300
stats-report-time = 60
max-ban-score = 50
ban-reset-time = 1200

# Настройки IP
default-domain = $DOMAIN
ipv4-network = 192.168.10.0
ipv4-netmask = 255.255.255.0
tunnel-all-dns = true
dns = 8.8.8.8
dns = 1.1.1.1

# Исключения (Split Tunneling)
no-route = 192.168.0.0/255.255.0.0
no-route = 10.0.0.0/255.0.0.0
no-route = 172.16.0.0/255.240.0.0
EOF

    # Добавляем пользовательские исключения в ocserv
    if [[ -n "${VPN_EXCLUDE_ROUTES:-}" ]]; then
        IFS=',' read -ra ADDR <<< "$VPN_EXCLUDE_ROUTES"
        for i in "${ADDR[@]}"; do
            echo "no-route = ${i// /}" >> /etc/ocserv/ocserv.conf
        done
    fi

    cat >> /etc/ocserv/ocserv.conf <<EOF
predictable-ips = true
ping-leases = true

# Ключи TLS: обновление без разрыва соединения
rekey-time = 86400
rekey-method = ssl

# Совместимость
cisco-client-compat = true
dtls-psk = true
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-SSL3.0:-ARCFOUR-128"
route = default
EOF

    # 4. Создание пользователя
    local oc_user="${VPN_USER:-vpnuser}"
    local oc_pass="${VPN_PASS}"
    touch /etc/ocserv/ocpasswd
    # Use heredoc to avoid password appearing in ps aux / shell history
    ocpasswd -c /etc/ocserv/ocpasswd "$oc_user" <<EOF
${oc_pass}
${oc_pass}
EOF
    unset oc_pass
    chmod 600 /etc/ocserv/ocpasswd
    
    # 5. Сеть (NAT через UFW и MSS Clamping)
    firewall_configure_nat "192.168.10.0/24"
    firewall_allow "${PORT_OPENCONNECT:-4443}" tcp
    firewall_allow "${PORT_OPENCONNECT:-4443}" udp

    # MSS Clamping — применяем немедленно и сохраняем в UFW before.rules для персистентности.
    # --clamp-mss-to-pmtu автоматически выставляет MSS = PMTU - 40, что корректно
    # для туннельного интерфейса с mtu=1200 (1200-40=1160, а не захардкоженные 1300).
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -s 192.168.10.0/24 -j TCPMSS --clamp-mss-to-pmtu || true
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -d 192.168.10.0/24 -j TCPMSS --clamp-mss-to-pmtu || true

    # Персистентность mangle-правил через UFW before.rules (аналогично блоку *nat).
    # UFW при ufw enable/reload делает iptables-restore и затирает все ручные правила.
    if ! grep -q "^\*mangle" /etc/ufw/before.rules; then
        log "Добавление блока *mangle в UFW before.rules для персистентности MSS clamping..."
        local temp_mangle
        temp_mangle="$(mktemp -p /etc/ufw)" || die "mktemp failed in /etc/ufw"
        local filter_line
        filter_line=$(grep -n "^\*filter" /etc/ufw/before.rules | head -n 1 | cut -d: -f1)
        [[ -z "$filter_line" ]] && filter_line=1
        head -n $((filter_line - 1)) /etc/ufw/before.rules > "$temp_mangle"
        cat >> "$temp_mangle" <<'MANGLE_EOF'
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -s 192.168.10.0/24 -j TCPMSS --clamp-mss-to-pmtu
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -d 192.168.10.0/24 -j TCPMSS --clamp-mss-to-pmtu
COMMIT

MANGLE_EOF
        tail -n +$filter_line /etc/ufw/before.rules >> "$temp_mangle"
        mv "$temp_mangle" /etc/ufw/before.rules
        log "Блок *mangle добавлен в UFW before.rules."
    fi
    
    # 6. Запуск и проверка
    log "Запуск сервиса ocserv..."
    mkdir -p /run/ocserv # Гарантируем наличие папки для сокета
    systemctl daemon-reload
    systemctl enable ocserv
    systemctl restart ocserv
    
    sleep 3
    if ! systemctl is-active --quiet ocserv; then
        error "Сервис ocserv не запустился. Повторная проверка логов..."
        journalctl -u ocserv --no-pager | tail -n 10
        return 1
    fi

    success "OpenConnect успешно запущен на порту ${PORT_OPENCONNECT:-4443}."
}
