#!/usr/bin/env bash

module_mtproto_install() {
    [[ "${INSTALL_MTPROXY:-false}" == "true" ]] || return 0

    local mt_port="${PORT_MTPROXY:-8443}"
    local mt_conf_dir="/etc/mtproxy"
    local mt_repo_dir="/opt/mtproxy"
    local mt_binary="${mt_repo_dir}/teleproxy"
    local mt_user="_mtproxy"
    # Pinned, not "latest" — reproducible installs and a known-good SHA256SUMS to
    # verify against. Override via env var to move to a newer tested release.
    local mt_version="${MTPROXY_TELEPROXY_VERSION:-v4.15.0}"

    # Fake-TLS masking domain must be an external popular domain, not the server's own
    # domain — using the server's own domain creates a circular probe and reveals the proxy.
    local mt_domain="${MTPROXY_DOMAIN:-}"
    if [[ -z "$mt_domain" ]]; then
        mt_domain="www.google.com"
        warn "MTPROXY_DOMAIN не задан — используется резервный домен ${mt_domain}. Задайте MTPROXY_DOMAIN явно (через UI) для маскировки, правдоподобной для IP/ASN этого сервера."
    fi
    if [[ -n "${DOMAIN:-}" && "$mt_domain" == "${DOMAIN}" ]]; then
        warn "MTPROXY_DOMAIN совпадает с DOMAIN сервера (${DOMAIN}) — это создаёт circular-probe и может выдать прокси."
    fi

    # Check for existing installation
    if systemctl is-active --quiet mtproxy 2>/dev/null || [[ -x "$mt_binary" ]] || [[ -x "/opt/mtproxy/mtg" ]] || [[ -x "/opt/mtproxy/objs/bin/mtproto-proxy" ]]; then
        if ! ui_ask_reinstall "MTProto Proxy (Teleproxy)"; then
            log "Пропуск установки MTProto Proxy."
            INSTALL_MTPROXY="skipped"
            return 0
        fi
    fi

    log "Установка MTProto Proxy (Teleproxy ${mt_version})..."
    apt-get install -y curl

    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)
            error "Неподдерживаемая архитектура: $(uname -m) (Teleproxy публикует только amd64/arm64)"
            return 1
            ;;
    esac

    # --- Stage and verify the new binary BEFORE touching any existing install ---
    # mktemp under /opt so the later swap into $mt_repo_dir is a same-filesystem
    # rename (atomic), not a cross-filesystem copy.
    mkdir -p /opt
    local mt_stage
    mt_stage=$(mktemp -d -p /opt .mtproxy-stage.XXXXXX) || { error "Не удалось создать временный каталог для установки"; return 1; }

    local mt_bin_url="https://github.com/teleproxy/teleproxy/releases/download/${mt_version}/teleproxy-linux-${arch}"
    local mt_sums_url="https://github.com/teleproxy/teleproxy/releases/download/${mt_version}/SHA256SUMS"

    log "Загрузка Teleproxy ${mt_version} (${arch})..."
    if ! curl -fsSL "$mt_bin_url" -o "${mt_stage}/teleproxy" || ! curl -fsSL "$mt_sums_url" -o "${mt_stage}/SHA256SUMS"; then
        error "Не удалось скачать Teleproxy ${mt_version} или файл контрольных сумм."
        rm -rf "$mt_stage"
        return 1
    fi

    local mt_expected_sum mt_actual_sum
    mt_expected_sum=$(awk -v f="teleproxy-linux-${arch}" '$2==f{print $1}' "${mt_stage}/SHA256SUMS")
    if [[ -z "$mt_expected_sum" ]]; then
        error "SHA256SUMS не содержит запись для teleproxy-linux-${arch} — установка прервана."
        rm -rf "$mt_stage"
        return 1
    fi
    mt_actual_sum=$(sha256sum "${mt_stage}/teleproxy" | awk '{print $1}')
    if [[ "$mt_actual_sum" != "$mt_expected_sum" ]]; then
        error "Проверка целостности Teleproxy не пройдена (ожидалось ${mt_expected_sum}, получено ${mt_actual_sum}) — установка прервана."
        rm -rf "$mt_stage"
        return 1
    fi
    log "Контрольная сумма Teleproxy ${mt_version} подтверждена."
    chmod +x "${mt_stage}/teleproxy"

    # Smoke-test in isolation, still nothing live has been touched yet.
    if ! "${mt_stage}/teleproxy" generate-secret smoke-test.invalid 2>/dev/null | grep -qE '^ee[a-f0-9]+$'; then
        error "Бинарник Teleproxy не прошёл smoke-test (generate-secret) — установка прервана."
        rm -rf "$mt_stage"
        return 1
    fi
    log "Smoke-test бинарника Teleproxy пройден."

    # --- Snapshot the current install (if any) so a failed swap can be rolled back ---
    local mt_backup_dir=""
    if [[ -d "$mt_repo_dir" || -d "$mt_conf_dir" || -f /etc/systemd/system/mtproxy.service ]]; then
        mt_backup_dir="/opt/.mtproxy-rollback-$(date +%Y%m%d%H%M%S)"
        log "Резервное копирование текущей установки в ${mt_backup_dir}..."
        mkdir -p "$mt_backup_dir"
        [[ -d "$mt_repo_dir" ]] && cp -a "$mt_repo_dir" "${mt_backup_dir}/repo"
        [[ -d "$mt_conf_dir" ]] && cp -a "$mt_conf_dir" "${mt_backup_dir}/conf"
        [[ -f /etc/systemd/system/mtproxy.service ]] && cp -a /etc/systemd/system/mtproxy.service "${mt_backup_dir}/mtproxy.service"
    fi

    systemctl stop mtproxy 2>/dev/null || true

    rm -rf "$mt_repo_dir" "$mt_conf_dir"
    mkdir -p "$mt_repo_dir" "$mt_conf_dir"
    mv -f "${mt_stage}/teleproxy" "$mt_binary"
    rmdir "$mt_stage" 2>/dev/null || rm -rf "$mt_stage"

    # Secret handling:
    # - MTPROXY_SECRET is stored as the full ee-secret (ee + 32hex_key + hex-encoded domain).
    # - Teleproxy's [[secret]] key= wants just the 32-hex key; the domain is configured
    #   separately via the top-level `domain =` TOML key below.
    # - Only rotate (generate a brand-new key) when the disguise domain actually changes.
    #   An unchanged domain must reuse the exact stored secret untouched — reinstalling
    #   should not invalidate proxy links already handed out.
    local mt_existing="${MTPROXY_SECRET:-}"
    local mt_ee_secret="" mt_key=""
    local mt_existing_key="" mt_existing_domain=""

    if [[ "$mt_existing" =~ ^ee([a-f0-9]{32})([a-f0-9]*)$ ]]; then
        mt_existing_key="${BASH_REMATCH[1]}"
        [[ -n "${BASH_REMATCH[2]}" ]] && mt_existing_domain=$(hex_decode_ascii "${BASH_REMATCH[2]}")
    fi

    if [[ -n "$mt_existing_key" && "$mt_existing_domain" == "$mt_domain" ]]; then
        mt_ee_secret="$mt_existing"
        mt_key="$mt_existing_key"
        log "Домен маскировки не изменился, секрет не тронут."
    else
        [[ -n "$mt_existing_key" ]] && log "Домен маскировки изменился (${mt_existing_domain:-<нет>} → ${mt_domain}), ротация секрета..."
        log "Генерация Fake-TLS секрета для домена ${mt_domain}..."
        # "Secret for -S:" goes to stderr; the ee-secret itself is the only stdout line.
        # Derive the raw key from the ee-secret directly instead of parsing stderr.
        mt_ee_secret=$("$mt_binary" generate-secret "$mt_domain" 2>/dev/null)
        if [[ "$mt_ee_secret" =~ ^ee([a-f0-9]{32}) ]]; then
            mt_key="${BASH_REMATCH[1]}"
        else
            error "Не удалось сгенерировать секрет"
            return 1
        fi
    fi
    MTPROXY_SECRET="${mt_ee_secret}"

    if ! id "$mt_user" &>/dev/null; then
        useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$mt_user"
    fi

    # Config file (TOML)
    # direct = true: подключается напрямую к Telegram DC без ME relay
    # domain: Fake-TLS маскировка — трафик неотличим от HTTPS к реальному сайту
    # MSS clamp включён по умолчанию: фрагментирует ClientHello, ломая DPI-реассемблинг
    cat > "${mt_conf_dir}/config.toml" <<EOF
port = ${mt_port}
direct = true
domain = "${mt_domain}"

[[secret]]
key = "${mt_key}"
EOF
    chmod 600 "${mt_conf_dir}/config.toml"
    chown "$mt_user:$mt_user" "${mt_conf_dir}/config.toml"

    # The service runs as an unprivileged user; binding a port below 1024
    # (e.g. an explicitly chosen 443 on a dedicated IP) needs an explicit
    # capability grant or the process exits immediately with EACCES.
    local mt_cap_lines=""
    if (( mt_port < 1024 )); then
        mt_cap_lines=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
    fi

    cat > /etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=Teleproxy MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${mt_user}
Group=${mt_user}
WorkingDirectory=${mt_repo_dir}
ExecStart=${mt_binary} --config ${mt_conf_dir}/config.toml
${mt_cap_lines}Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtproxy
    systemctl restart mtproxy

    # "active" only proves the process didn't immediately crash — it does not prove
    # the process is actually listening on the port we just configured for it.
    local mt_started=false
    local i
    for (( i=0; i<15; i++ )); do
        sleep 2
        if systemctl is-active --quiet mtproxy; then
            mt_started=true
            break
        fi
    done

    local mt_listening=false
    if [[ "$mt_started" == "true" ]]; then
        for (( i=0; i<5; i++ )); do
            if port_in_use_by_pattern "$mt_port" "teleproxy" tcp; then
                mt_listening=true
                break
            fi
            sleep 1
        done
    fi

    if [[ "$mt_started" == "true" && "$mt_listening" == "true" ]]; then
        firewall_allow "$mt_port" tcp
        success "MTProto Proxy (Teleproxy ${mt_version}) запущен и слушает порт ${mt_port}/TCP."
        [[ -n "$mt_backup_dir" ]] && rm -rf "$mt_backup_dir"

        # The client-facing link needs the server's real public IP/hostname —
        # DOMAIN, never MTPROXY_DOMAIN (that's the Fake-TLS masking SNI value,
        # not an address this host actually answers on).
        local mt_public_host="${DOMAIN:-}"
        if [[ -z "$mt_public_host" ]]; then
            error "DOMAIN (публичный адрес сервера) не задан — proxy-ссылку построить нельзя. Задайте DOMAIN (домен или IP) и перезапустите установку MTProto."
        else
            local mt_tg_link mt_https_link
            mt_tg_link=$(mtproto_proxy_link_tg "$mt_public_host" "$mt_port" "$mt_ee_secret")
            mt_https_link=$(mtproto_proxy_link_https "$mt_public_host" "$mt_port" "$mt_ee_secret")
            echo ""
            echo "===== MTProto Proxy — ссылка для подключения ====="
            echo "$mt_tg_link"
            echo "(эквивалент: $mt_https_link)"
            echo "===================================================="
        fi
        return 0
    fi

    error "Сервис mtproxy не в рабочем состоянии (active=${mt_started}, listening=${mt_listening}). Журнал:"
    journalctl -u mtproxy --no-pager -n 40

    if [[ -n "$mt_backup_dir" ]]; then
        error "Откат к предыдущей рабочей установке..."
        systemctl stop mtproxy 2>/dev/null || true
        rm -rf "$mt_repo_dir" "$mt_conf_dir" /etc/systemd/system/mtproxy.service
        [[ -d "${mt_backup_dir}/repo" ]] && mv "${mt_backup_dir}/repo" "$mt_repo_dir"
        [[ -d "${mt_backup_dir}/conf" ]] && mv "${mt_backup_dir}/conf" "$mt_conf_dir"
        [[ -f "${mt_backup_dir}/mtproxy.service" ]] && mv "${mt_backup_dir}/mtproxy.service" /etc/systemd/system/mtproxy.service
        rm -rf "$mt_backup_dir"
        systemctl daemon-reload
        systemctl restart mtproxy
        if systemctl is-active --quiet mtproxy; then
            error "Откат выполнен — восстановлена предыдущая рабочая версия MTProto Proxy."
        else
            error "ОТКАТ НЕ УДАЛСЯ — mtproxy не в рабочем состоянии. Требуется ручное вмешательство."
        fi
    else
        error "Предыдущей рабочей установки не было (свежая установка) — откатывать нечего."
    fi

    return 1
}
