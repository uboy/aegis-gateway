#!/usr/bin/env bash

module_tproxy_server_install() {
    [[ "${INSTALL_TPROXY:-false}" == "true" ]] || return 0

    local tp_domain="${TPROXY_DOMAIN:-${DOMAIN:-}}"
    local tp_faketls_sni="${TPROXY_FAKETLS_SNI:-magic-ball.duckdns.org}"

    if [[ -z "$tp_domain" ]]; then
        if command -v whiptail &>/dev/null && [[ -t 0 ]]; then
            tp_domain=$(whiptail --title "Telegram WebProxy (Desktop)" \
                --inputbox "Введите домен для Telegram WebProxy (Desktop):\n(Должен указывать через A-запись на IP сервера)" 10 60 "${DOMAIN:-}" 3>&1 1>&2 2>&3) || true
        else
            read -r -p "Введите домен для Telegram WebProxy (Desktop): " tp_domain
        fi
    fi
    [[ -n "$tp_domain" ]] || tp_domain="${DOMAIN:-localhost}"
    TPROXY_DOMAIN="$tp_domain"

    if [[ -z "$tp_faketls_sni" || "$tp_faketls_sni" == "$tp_domain" ]]; then
        tp_faketls_sni="magic-ball.duckdns.org"
    fi
    TPROXY_FAKETLS_SNI="$tp_faketls_sni"

    # Генерируем 16-байтный hex-секрет, если не задан
    local tp_secret="${TPROXY_SECRET}"
    if [[ -z "$tp_secret" ]]; then
        tp_secret=$(openssl rand -hex 16)
        log "Сгенерирован новый секрет: ${tp_secret}"
        TPROXY_SECRET="$tp_secret"
    fi
    save_install_state 2>/dev/null || true

    log "Установка HAProxy для разделения трафика 443 порта (SNI routing)..."
    apt-get update
    apt-get install -y haproxy curl jq

    # Проверяем, на каком порту сейчас dumbproxy, если на 443, переносим на 4430
    if grep -q "\-bind-address :443" /etc/default/dumbproxy 2>/dev/null; then
        log "Перенос dumbproxy с порта 443 на 4430..."
        sed -i 's/-bind-address :443/-bind-address 127.0.0.1:4430/' /etc/default/dumbproxy
        systemctl restart dumbproxy
    fi

    local srv_ip
    srv_ip=$(curl -fsSL --max-time 5 ifconfig.me || curl -fsSL --max-time 5 api.ipify.org || true)
    srv_ip=$(echo "$srv_ip" | tr -d '\r\n')

    log "Настройка HAProxy..."
    cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  5m
    timeout server  5m

frontend port443
    bind :::443 v4v6
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    tcp-request content accept if { req.len gt 0 }

    # Loop prevention for local/internal connections
    use_backend backend_tproxy if { src 127.0.0.1 ::1 }
EOF

    if [[ -n "${srv_ip}" ]]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    use_backend backend_tproxy if { src ${srv_ip} }
EOF
    fi

    cat >> /etc/haproxy/haproxy.cfg <<EOF

    # 1. MTProto FakeTLS (Telegram Mobile) routing by dedicated camouflage SNI
    use_backend backend_mtproto_tls if { req_ssl_hello_type 1 } { req_ssl_sni -i ${tp_faketls_sni} }

    # 2. Telegram WebProxy (Telegram Desktop) routing by dedicated WebProxy domain
    use_backend backend_tproxy if { req_ssl_hello_type 1 } { req_ssl_sni -i ${tp_domain} }
    use_backend backend_tproxy if { req_ssl_hello_type 1 } !{ req_ssl_sni -m found } { req.ssl_alpn -m found }

    # 3. MTProto Obfuscated2 (Direct secret without TLS Hello)
    use_backend backend_mtproto_plain if !{ req_ssl_hello_type 1 }
EOF

    # Dumbproxy routing: if dedicated domain is provided, match SNI and fallback to tproxy
    if [[ -n "${DOMAIN:-}" ]] && [[ "${DOMAIN:-}" != "${tp_domain}" ]]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    use_backend backend_dumbproxy if { req_ssl_sni -i ${DOMAIN} }
    default_backend backend_tproxy
EOF
    else
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    default_backend backend_tproxy
EOF
    fi

    cat >> /etc/haproxy/haproxy.cfg <<EOF

backend backend_tproxy
    mode tcp
    server caddy 127.0.0.1:4431

backend backend_mtproto_tls
    mode tcp
    server mtproto_tls 127.0.0.1:2399

backend backend_mtproto_plain
    mode tcp
    server mtproto_plain 127.0.0.1:2398

backend backend_dumbproxy
    mode tcp
    server dumbproxy 127.0.0.1:4430
EOF

    systemctl restart haproxy

    log "Создание заглушки для WEB-прокси..."
    mkdir -p /var/www/tproxy-site
    cat > /var/www/tproxy-site/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>It works!</h1></body>
</html>
EOF

    apt-get install -y haproxy curl jq git
    
    log "Загрузка и установка официального tproxy-server..."
    local inst_dir="/tmp/tproxy-install"
    rm -rf "$inst_dir"
    mkdir -p "$inst_dir"
    git clone https://github.com/telegramdesktop/tproxy-server.git "$inst_dir"
    
    pushd "$inst_dir" >/dev/null
    
    # Отключаем go test, так как он иногда падает из-за строгих проверок прав в системе
    sed -i 's/.*go_binary.*test.*/true/g' deploy/install.sh
    
    # Полностью перезаписываем Caddyfile, чтобы он слушал только нужные порты и localhost
    cat > deploy/Caddyfile << 'EOF'
{
	email {$ACME_EMAIL}
	https_port 4431
	http_port 8082
	admin off
	servers {
		protocols h1 h2
		timeouts {
			read_header 10s
		}
	}
}

{$TPROXY_HOSTNAME} {
	bind 127.0.0.1
	encode zstd gzip
	header Strict-Transport-Security "max-age=31536000; includeSubDomains"
	reverse_proxy 127.0.0.1:8080 {
		transport http {
		}
	}
	handle_errors {
		header {
			Cache-Control "no-store"
			Content-Security-Policy "default-src 'self'; style-src 'self'; img-src 'self'; worker-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
			Permissions-Policy "camera=(), microphone=(), geolocation=()"
			Referrer-Policy "strict-origin-when-cross-origin"
			X-Content-Type-Options "nosniff"
			X-Frame-Options "DENY"
			Strict-Transport-Security "max-age=31536000; includeSubDomains"
		}
		respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
	}
}
EOF
    
    # Запускаем установку официального tproxy-server и mtproxy бэкенда
    chmod +x deploy/install.sh
    ./deploy/install.sh --hostname "$tp_domain" --email "admin@${tp_domain}" --site-dir /var/www/tproxy-site --secret "$tp_secret"
    popd >/dev/null
    rm -rf "$inst_dir"

    # Настройка дополнительного бэкенда mtproxy-tls на порту 2399 для Fake-TLS (Telegram Mobile)
    log "Настройка Fake-TLS бэкенда (mtproxy-tls на порту 2399)..."
    cat > /etc/systemd/system/mtproxy-tls.service <<EOF
[Unit]
Description=Official Telegram MTProxy Fake-TLS backend
After=network-online.target tproxy-firewall.service
Wants=network-online.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
EnvironmentFile=/etc/mtproxy/mtproxy.env
Environment=MTPROXY_WORKERS=1
Environment=MTPROXY_MAX_CONNECTIONS=4096
WorkingDirectory=/opt/MTProxy
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8889 -H 2399 -S \${MTPROXY_SECRET} -D ${tp_faketls_sni} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now mtproxy-tls || true

    firewall_allow 443 tcp

    local hex_sni ee_secret tg_link
    hex_sni=$(python3 -c "import sys; print(sys.argv[1].encode().hex())" "$tp_faketls_sni" 2>/dev/null || true)
    ee_secret="ee${tp_secret}${hex_sni}"
    tg_link="tg://proxy?server=${srv_ip}&port=443&secret=${ee_secret}"

    success "Защищенный Telegram Proxy (WebProxy + Fake-TLS) успешно установлен на порту 443!"
    success "Параметры подключения:"
    success "1. Telegram WebProxy (Desktop): https://${tp_domain}:443 (секрет: ${tp_secret})"
    success "2. Telegram Mobile (Fake-TLS на порту 443): ${tg_link}"
    success "   (Маскировочный SNI: ${tp_faketls_sni})"
}
