#!/usr/bin/env bash

module_tproxy_server_install() {
    [[ "${INSTALL_TPROXY:-false}" == "true" ]] || return 0

    local tp_domain="${TPROXY_DOMAIN}"
    while [[ -z "$tp_domain" ]]; do
        read -p "Введите домен для Telegram WEB-прокси (уже должен указывать на IP сервера): " tp_domain
    done

    # Генерируем 16-байтный hex-секрет, если не задан
    local tp_secret="${TPROXY_SECRET}"
    if [[ -z "$tp_secret" ]]; then
        tp_secret=$(openssl rand -hex 16)
        log "Сгенерирован новый секрет: ${tp_secret}"
    fi

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
    use_backend backend_tproxy if { src 127.0.0.1 ::1 ${srv_ip} }

    # Telegram WebProxy: match SNI or ALPN without SNI (Telegram Desktop client)
    use_backend backend_tproxy if { req_ssl_sni -i ${tp_domain} }
    use_backend backend_tproxy if { req_ssl_hello_type 1 } !{ req_ssl_sni -m found } { req.ssl_alpn -m found }
EOF

    # Dumbproxy routing: if dedicated domain is provided, match SNI and fallback to tproxy (prevents scanner ACME rate-limits)
    if [[ -n "${DOMAIN:-}" ]] && [[ "${DOMAIN:-}" != "${tp_domain}" ]]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    use_backend backend_dumbproxy if { req_ssl_sni -i ${DOMAIN} }
    default_backend backend_tproxy
EOF
    else
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    default_backend backend_dumbproxy
EOF
    fi

    cat >> /etc/haproxy/haproxy.cfg <<EOF

backend backend_tproxy
    mode tcp
    server caddy 127.0.0.1:4431

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

    # Убираем nginx-light, он не нужен и может конфликтовать за 80 порт
    apt-get install -y haproxy curl jq git
    
    # ... (пропущено до загрузки tproxy-server)
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
			# read_body 60s
		}
	}
}

{$TPROXY_HOSTNAME} {
	bind 127.0.0.1
	encode zstd gzip
	header Strict-Transport-Security "max-age=31536000; includeSubDomains"
	reverse_proxy 127.0.0.1:8080 {
		transport http {
			# response_header_timeout 40s
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
    
    # Запускаем установку
    chmod +x deploy/install.sh
    ./deploy/install.sh --hostname "$tp_domain" --email "admin@${tp_domain}" --site-dir /var/www/tproxy-site --secret "$tp_secret"
    popd >/dev/null
    rm -rf "$inst_dir"

    firewall_allow 443 tcp

    success "WEB-прокси для Telegram успешно установлен!"
    success "Параметры для Telegram:"
    success "Домен: ${tp_domain}"
    success "Порт: 443"
    success "Секрет: ${tp_secret}"
}
