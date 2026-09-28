#!/usr/bin/env bash

cert_install_tools() {
    log "Установка Certbot..."
    apt-get install -y certbot
}

cert_issue_standalone() {
    local domain="$1"
    local email="$2"
    
    # Проверяем, является ли "domain" IP-адресом
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Let's Encrypt не поддерживает IP-адреса ($domain). Генерируем самоподписанный сертификат..."
        mkdir -p "/etc/letsencrypt/live/$domain"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "/etc/letsencrypt/live/$domain/privkey.pem" \
            -out "/etc/letsencrypt/live/$domain/fullchain.pem" \
            -subj "/CN=$domain"
        chmod 600 "/etc/letsencrypt/live/$domain/privkey.pem"
        chmod 644 "/etc/letsencrypt/live/$domain/fullchain.pem"
        success "Самоподписанный сертификат для IP $domain создан."
        return 0
    fi

    log "Получение SSL сертификата Let's Encrypt для $domain..."

    # Pre-flight: network connectivity to Let's Encrypt
    if ! curl -sf --max-time 5 https://acme-v02.api.letsencrypt.org/directory >/dev/null; then
        error "Нет подключения к Let's Encrypt API (acme-v02.api.letsencrypt.org)"
        return 1
    fi

    # Pre-flight: DNS resolution
    if ! getent hosts "$domain" >/dev/null 2>&1; then
        error "Домен $domain не резолвится — проверьте DNS записи"
        return 1
    fi

    # Останавливаем временно службы на 80 порту если есть
    local _nginx_was_running=false
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        _nginx_was_running=true
        systemctl stop nginx
    fi

    # Запуск certbot
    local _certbot_rc=0
    certbot certonly --standalone \
        --non-interactive --agree-tos --email "$email" \
        -d "$domain" || _certbot_rc=$?

    if [[ "$_nginx_was_running" == true ]]; then
        systemctl start nginx || warn "nginx не удалось перезапустить"
    fi

    if (( _certbot_rc == 0 )); then
        success "Сертификат для $domain успешно получен."
        return 0
    else
        error "Не удалось получить сертификат Let's Encrypt. Проверьте DNS или доступность порта 80."
        return 1
    fi
}
