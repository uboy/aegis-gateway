#!/usr/bin/env bash

module_hardening_apply() {
    log "--- Начало настройки безопасности (Hardening) ---"
    
    # 1. Настройка Fail2Ban
    log "Настройка Fail2Ban для защиты SSH..."
    apt-get install -y fail2ban
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT:-22}
maxretry = 5
findtime = 10m
bantime = 1h
banaction = ufw
EOF
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    success "Fail2Ban настроен и запущен."

    # 2. Создание пользователя
    if [[ "$INSTALL_MODE" == "super-secure" ]]; then
        local admin_user="${NEW_USER:-vpnadmin}"

        # Validate username before any system changes
        is_valid_username "$admin_user" || die "Invalid admin username: $admin_user"

        local admin_pass="${NEW_PASS:-}"
        if ! id -u "$admin_user" >/dev/null 2>&1; then
            log "Создание администратора системы: $admin_user..."
            adduser --disabled-password --gecos "" "$admin_user"
            [[ -z "$admin_pass" ]] && admin_pass=$(generate_strong_secret)
            usermod -aG sudo "$admin_user"
            NEW_USER="$admin_user"
        fi

        if [[ -n "$admin_pass" ]]; then
            log "Обновление пароля для $admin_user..."
            echo "$admin_user:$admin_pass" | chpasswd
            NEW_PASS="$admin_pass"
        fi

        # Full NOPASSWD sudo for admin user
        local sudoers_file="/etc/sudoers.d/90-aegis-${admin_user}"
        {
            echo "# Aegis Gateway — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "${admin_user} ALL=(ALL) NOPASSWD: ALL"
        } > "$sudoers_file"
        chmod 440 "$sudoers_file"
        visudo -c -f "$sudoers_file" || { rm -f "$sudoers_file"; die "sudoers syntax error — file removed"; }
        success "Пользователь $admin_user создан и добавлен в sudoers (NOPASSWD: ALL)."

        # Копируем authorized_keys из root, чтобы пользователь мог заходить тем же ключом
        local user_ssh_dir="/home/${admin_user}/.ssh"
        mkdir -p "$user_ssh_dir"
        if [[ -f /root/.ssh/authorized_keys ]]; then
            cp /root/.ssh/authorized_keys "${user_ssh_dir}/authorized_keys"
            chown -R "${admin_user}:${admin_user}" "$user_ssh_dir"
            chmod 700 "$user_ssh_dir"
            chmod 600 "${user_ssh_dir}/authorized_keys"
            success "SSH ключи скопированы из root в ${admin_user}."
        else
            chown -R "${admin_user}:${admin_user}" "$user_ssh_dir"
            chmod 700 "$user_ssh_dir"
            warn "У root нет /root/.ssh/authorized_keys — SSH ключ для $admin_user не скопирован."
        fi

        # 3. Харденинг SSH
        log "Применение настроек SSH (Порт: ${SSH_PORT:-22}, Root: No)..."

        # Timestamped backup
        local bak_dir="/etc/ssh/backups"
        mkdir -p "$bak_dir"
        cp /etc/ssh/sshd_config "${bak_dir}/sshd_config.$(date +%Y%m%d_%H%M%S)"

        sed -i "s/^#\?Port .*/Port ${SSH_PORT:-22}/" /etc/ssh/sshd_config
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
        # Note: PasswordAuthentication remains yes for initial access; configure key-based auth post-install
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config

        if ! grep -q "AllowUsers" /etc/ssh/sshd_config; then
            echo "AllowUsers $admin_user" >> /etc/ssh/sshd_config
        fi

        # Validate SSH config before allowing restart
        if ! sshd -t -f /etc/ssh/sshd_config 2>&1; then
            error "Конфигурация SSH содержит ошибки — восстанавливаем последний бекап"
            local last_bak
            last_bak=$(ls -1t "$bak_dir"/ | head -1)
            cp "${bak_dir}/${last_bak}" /etc/ssh/sshd_config
            die "SSH config rejected — restored from backup"
        fi

        success "Конфигурация SSH обновлена (бекапы в ${bak_dir})."
        warn "Примечание: PasswordAuthentication=yes. Настройте key-based auth и отключите пароли после входа."
    fi
}
