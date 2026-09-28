#!/usr/bin/env bash

module_amnezia_install() {
    [[ "$INSTALL_AMNEZIA" == "true" ]] || return 0

    log "Установка нативной версии AmneziaWG (Kernel Module + Tools)..."

    local old_umask
    old_umask=$(umask)
    umask 077 # Защита от TOCTOU: файлы создаются с правами 600 (drwx------)

    # Очистка старой docker-установки (если была)
    local AMN_DOCKER_DIR="/opt/amnezia"
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^amneziawg$"; then
        log "Удаление старой Docker-версии AmneziaWG..."
        cd "$AMN_DOCKER_DIR" || true
        docker compose down -v 2>/dev/null || true
        cd - >/dev/null || true
        rm -rf "$AMN_DOCKER_DIR"
    fi

    # Установка PPA и пакетов
    if ! dpkg-query -W -f='${Status}' amneziawg-tools 2>/dev/null | grep -q "ok installed"; then
        log "Добавление репозитория ppa:amnezia/ppa..."
        apt-get install -y software-properties-common
        add-apt-repository -y ppa:amnezia/ppa || { umask "$old_umask"; error "Не удалось добавить PPA amnezia"; return 1; }
        apt-get update
        apt-get install -y amneziawg-tools amneziawg-dkms || { umask "$old_umask"; error "Не удалось установить пакеты amneziawg"; return 1; }
    fi

    local AWG_DIR="/etc/amnezia/amneziawg"
    mkdir -p "$AWG_DIR"
    mkdir -p "${AWG_DIR}/clients"

    local PORT=${PORT_AMNEZIA:-39442}

    if [[ -f "${AWG_DIR}/awg0.conf" ]]; then
        log "Конфигурация AmneziaWG уже существует (${AWG_DIR}/awg0.conf), пропускаем генерацию."
    else
        log "Генерация серверных ключей..."
        local private_key
        private_key=$(awg genkey)
        local public_key
        public_key=$(echo "$private_key" | awg pubkey)

        # Определяем внешний интерфейс для NAT
        local ext_if
        ext_if=$(ip -4 route ls | grep default | awk '{print $5}' | head -1)
        if [[ -z "$ext_if" ]]; then
            ext_if="eth0"
        fi
        
        # Генерация параметров обфускации
        # Jmax снижен до 256 для предотвращения фрагментации UDP пакетов при MTU 1420
        local jc=$(shuf -i 3-10 -n 1)
        local jmin=$(shuf -i 15-50 -n 1)
        local jmax=$(shuf -i 51-256 -n 1)
        local s1=$(shuf -i 15-150 -n 1)
        local s2=$(shuf -i 15-150 -n 1)
        
        # H1-H4 используют полный диапазон 32-битного INT для максимизации энтропии первого байта
        local h1=$(shuf -i 1-2147483647 -n 1)
        local h2=$(shuf -i 1-2147483647 -n 1)
        local h3=$(shuf -i 1-2147483647 -n 1)
        local h4=$(shuf -i 1-2147483647 -n 1)

        log "Создание конфигурации awg0..."
        cat > "${AWG_DIR}/awg0.conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = 10.99.0.1/24
ListenPort = $PORT
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4

PostUp = iptables -A FORWARD -i %i -o "$ext_if" -j ACCEPT; iptables -A FORWARD -i "$ext_if" -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -o "$ext_if" -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o "$ext_if" -j ACCEPT; iptables -D FORWARD -i "$ext_if" -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -o "$ext_if" -j MASQUERADE
EOF

        log "Создание клиентских конфигураций (3 клиента)..."
        local endpoint
        endpoint="${DOMAIN:-$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org)}"
        # Убираем возможные переносы строк из домена для предотвращения инъекций в конфиг
        endpoint=$(echo "$endpoint" | tr -d '\r\n')

        for i in 1 2 3; do
            local c_priv
            c_priv=$(awg genkey)
            local c_pub
            c_pub=$(echo "$c_priv" | awg pubkey)
            local c_psk
            c_psk=$(awg genpsk)
            local client_ip="10.99.0.$((i+1))"

            # Добавление пира в серверный конфиг
            echo "" >> "${AWG_DIR}/awg0.conf"
            echo "# Client $i" >> "${AWG_DIR}/awg0.conf"
            echo "[Peer]" >> "${AWG_DIR}/awg0.conf"
            echo "PublicKey = $c_pub" >> "${AWG_DIR}/awg0.conf"
            echo "PresharedKey = $c_psk" >> "${AWG_DIR}/awg0.conf"
            echo "AllowedIPs = $client_ip/32" >> "${AWG_DIR}/awg0.conf"

            # Создание клиентского файла
            cat > "${AWG_DIR}/clients/amnezia-client${i}.conf" <<EOF
[Interface]
Address = $client_ip/32
PrivateKey = $c_priv
DNS = 10.99.0.1, 1.1.1.1
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4

# Peer Name: Server
[Peer]
PublicKey = $public_key
PresharedKey = $c_psk
Endpoint = ${endpoint}:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
        done

        log "Запуск службы awg-quick@awg0..."
        systemctl enable awg-quick@awg0
        systemctl restart awg-quick@awg0 || { umask "$old_umask"; error "Ошибка при запуске интерфейса awg0"; return 1; }
    fi

    # Защита от симлинк-атаки (Local Privilege Escalation)
    if [[ -n "${NEW_USER:-}" ]] && [[ -d "/home/${NEW_USER}" ]] && [[ -f "${AWG_DIR}/clients/amnezia-client1.conf" ]]; then
        rm -f "/home/${NEW_USER}/amnezia_client1.conf" # Удаляем симлинк, если он был создан злоумышленником
        cp "${AWG_DIR}/clients/amnezia-client1.conf" "/home/${NEW_USER}/amnezia_client1.conf"
        chown "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/amnezia_client1.conf"
    fi

    # Ключи удалены из Base64 вывода для предотвращения утечек в логи Ansible/Terraform

    firewall_allow "$PORT" udp
    umask "$old_umask"
    success "AmneziaWG успешно установлен/проверен нативно (Kernel Module)."
}
