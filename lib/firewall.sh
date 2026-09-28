#!/usr/bin/env bash

firewall_init() {
    log "Инициализация фаервола (UFW)..."
    apt-get install -y ufw

    # Разрешаем форвардинг трафика (нужно для VPN)
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    # UFW не раскомментирует ip_forward автоматически — делаем явно
    sed -i 's|#net/ipv4/ip_forward=1|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1

    ufw default deny incoming
    ufw default allow outgoing
}

firewall_configure_nat() {
    local subnet="$1"
    local eth
    eth=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+' | head -n 1)

    if [[ -z "$eth" ]]; then
        warn "Не удалось определить сетевой интерфейс для NAT."
        return 1
    fi

    # Validate inputs before touching system files
    is_valid_cidr "$subnet" || { error "Invalid subnet for NAT: $subnet"; return 1; }
    [[ "$eth" =~ ^[a-zA-Z0-9_-]{1,15}$ ]] || { error "Invalid interface name: $eth"; return 1; }

    log "Настройка NAT в UFW для подсети $subnet через интерфейс $eth..."

    # 1. Резервная копия
    [[ -f /etc/ufw/before.rules.orig ]] || cp /etc/ufw/before.rules /etc/ufw/before.rules.orig

    # 2. Если блока NAT вообще нет, вставляем его ПЕРЕД *filter
    if ! grep -q "^\*nat" /etc/ufw/before.rules; then
        log "Создание блока *nat..."
        local temp_file
        temp_file="$(mktemp -p /etc/ufw)" || { error "mktemp failed in /etc/ufw"; return 1; }
        # Находим строку начала блока *filter
        local filter_line
        filter_line=$(grep -n "^\*filter" /etc/ufw/before.rules | head -n 1 | cut -d: -f1)
        [[ -z "$filter_line" ]] && filter_line=1

        # Собираем файл заново: до фильтра + наш нат + остальное
        head -n $((filter_line - 1)) /etc/ufw/before.rules > "$temp_file"
        cat >> "$temp_file" <<EOF
*nat
:POSTROUTING ACCEPT [0:0]
COMMIT

EOF
        tail -n +$filter_line /etc/ufw/before.rules >> "$temp_file"
        mv "$temp_file" /etc/ufw/before.rules
    fi

    # 3. Добавляем правило маскарадинга
    local rule="-A POSTROUTING -s $subnet -o $eth -j MASQUERADE"
    if ! grep -Fq -- "$rule" /etc/ufw/before.rules; then
        log "Добавление правила MASQUERADE..."
        # Escape special chars for sed replacement side (|, &, \)
        local rule_escaped
        rule_escaped=$(printf '%s' "$rule" | sed 's/[|&\\/]/\\&/g')
        sed -i "/^\*nat/,/^COMMIT/ s|^COMMIT|${rule_escaped}\nCOMMIT|" /etc/ufw/before.rules
    fi

    # 4. При наличии Docker сохраняем правила маскарадинга для всех bridge-сетей.
    # ufw enable/reload сбрасывает nat-таблицу через iptables-restore, что удаляет
    # правила, добавленные Docker при старте контейнеров. Перечисляем все бриджи:
    # docker0 (дефолтная сеть) и br-XXXXXXXXXXXX (compose-сети, напр. DockOVPN).
    if command -v docker &>/dev/null; then
        local _iface _subnet _docker_rule _rule_esc
        while IFS= read -r _iface; do
            [[ -z "$_iface" ]] && continue
            _subnet=$(ip -4 addr show dev "$_iface" 2>/dev/null \
                      | grep -oP '(?<=inet )[\d.]+/\d+' | head -n 1)
            [[ -z "$_subnet" ]] && continue
            is_valid_cidr "$_subnet" || continue
            _docker_rule="-A POSTROUTING -s ${_subnet} ! -o ${_iface} -j MASQUERADE"
            if ! grep -Fq -- "$_docker_rule" /etc/ufw/before.rules; then
                log "Добавление MASQUERADE для Docker bridge ${_iface} (${_subnet})..."
                _rule_esc=$(printf '%s' "$_docker_rule" | sed 's/[|&\\/]/\\&/g')
                sed -i "/^\*nat/,/^COMMIT/ s|^COMMIT|${_rule_esc}\nCOMMIT|" /etc/ufw/before.rules
            fi
        done < <(ip link show \
                 | grep -oP '^[0-9]+:\s+\K(docker0|br-[a-f0-9]+)(?=:)')
    fi

    success "Конфигурация NAT обновлена."
}

firewall_allow() {
    local port="$1"
    local proto="${2:-tcp}"
    is_valid_port "$port" || { error "Invalid port: $port"; return 1; }
    log "Открытие порта $port/$proto..."
    ufw allow "$port/$proto"
}

firewall_enable() {
    log "Включение и перезапуск фаервола..."
    if ! echo "y" | ufw enable; then
        error "Ошибка UFW. Откат..."
        if [[ -f /etc/ufw/before.rules.orig ]]; then
            cp /etc/ufw/before.rules.orig /etc/ufw/before.rules
            echo "y" | ufw enable
        else
            error "Резервная копия /etc/ufw/before.rules.orig не найдена — требуется ручное вмешательство"
        fi
        return 1
    fi
    ufw reload
}

firewall_status() {
    ufw status verbose
}
