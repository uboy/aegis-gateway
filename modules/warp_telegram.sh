#!/usr/bin/env bash

module_warp_telegram_install() {
  log "Установка Cloudflare WARP (через wgcf) для обхода DPI для Telegram..."

  # Установка wireguard-tools, если еще не установлен
  if ! command -v wg-quick &>/dev/null; then
    apt-get update
    apt-get install -y --no-install-recommends wireguard-tools resolvconf
  fi

  local WORK_DIR="/tmp/warp_telegram_install"
  mkdir -p "$WORK_DIR"
  pushd "$WORK_DIR" >/dev/null

  # Скачивание wgcf
  log "Скачивание wgcf..."
  curl -sSLf -o wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.32/wgcf_2.2.32_linux_amd64" || {
    error "Не удалось скачать wgcf."
    popd >/dev/null
    return 1
  }
  chmod +x wgcf

  # Регистрация и генерация конфига
  if [[ -f /etc/wireguard/wgcf-account.toml ]]; then
    log "Аккаунт WARP уже существует, используем его..."
    cp /etc/wireguard/wgcf-account.toml ./wgcf-account.toml
    ./wgcf generate >/dev/null
  else
    log "Регистрация устройства в Cloudflare WARP..."
    ./wgcf register --accept-tos >/dev/null
    ./wgcf generate >/dev/null
    cp wgcf-account.toml /etc/wireguard/wgcf-account.toml
  fi

  if [[ ! -f wgcf-profile.conf ]]; then
    error "Не удалось сгенерировать конфигурацию WARP."
    popd >/dev/null
    return 1
  fi

  local TELEGRAM_IPS="91.105.192.0/23, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 149.154.160.0/20, 185.76.151.0/24"
  
  # Динамически получаем IP-адреса Google (Отключено: WARP сильно режет скорость YouTube)
  # local GOOGLE_IPS
  # if GOOGLE_IPS=$(curl -sSLf https://www.gstatic.com/ipranges/goog.json | grep -o '"ipv4Prefix": "[^"]*"' | cut -d '"' -f 4 | paste -sd, -); then
  #   if [[ -n "$GOOGLE_IPS" ]]; then
  #     TELEGRAM_IPS="${TELEGRAM_IPS}, ${GOOGLE_IPS}"
  #   fi
  # else
  #   warn "Не удалось получить IP-адреса Google. Обход DPI для YouTube может работать не полностью."
  # fi
  
  # Удаляем замену DNS
  sed -i 's/^DNS = /#DNS = /' wgcf-profile.conf
  
  # Заменяем дефолтный маршрут на список IP адресов Телеграма
  sed -i "s|AllowedIPs = 0.0.0.0/0|AllowedIPs = $TELEGRAM_IPS|" wgcf-profile.conf
  
  # Удаляем IPv6 из WARP (предотвращаем ошибки IPv6/таймауты)
  sed -i '/Address = 2606:/d' wgcf-profile.conf
  sed -i '/AllowedIPs = ::\/0/d' wgcf-profile.conf
  
  # Добавляем MASQUERADE для локальных VPN клиентов
  sed -i '/^MTU = /a PostUp = iptables -t nat -I POSTROUTING -o warp -j MASQUERADE\nPostDown = iptables -t nat -D POSTROUTING -o warp -j MASQUERADE' wgcf-profile.conf
  
  # Блокировка IPv6 для Telegram в ядре (чтобы клиенты моментально фоллбэчились на IPv4)
  # Пишем скрипт, который будет стартовать вместе с интерфейсом
  local IPV6_BLOCK_SCRIPT="/usr/local/bin/telegram_ipv6_block.sh"
  cat << 'EOF' > "$IPV6_BLOCK_SCRIPT"
#!/usr/bin/env bash
for ip in 2001:b28:f23d::/48 2001:b28:f23f::/48 2001:67c:4e8::/48 2001:b28:f23c::/48 2a0a:f280::/32; do
  ip -6 route add blackhole "$ip" 2>/dev/null || true
done
EOF
  chmod +x "$IPV6_BLOCK_SCRIPT"
  "$IPV6_BLOCK_SCRIPT" # Выполняем сразу
  
  # Добавляем вызов скрипта блокировки в PostUp, сразу после первого PostUp (MASQUERADE)
  sed -i "/^PostUp = iptables/a PostUp = $IPV6_BLOCK_SCRIPT" wgcf-profile.conf

  # Переносим конфигурацию в wireguard
  cp wgcf-profile.conf /etc/wireguard/warp.conf
  
  # Создание автообновлятора IP-адресов
  log "Настройка еженедельного автообновления IP-адресов Google..."
  local CRON_SCRIPT="/usr/local/bin/warp_update_ips.sh"
  cat << 'EOF' > "$CRON_SCRIPT"
#!/usr/bin/env bash
TELEGRAM_IPS="91.105.192.0/23, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 149.154.160.0/20, 185.76.151.0/24"
# Google IPs отключены: Cloudflare WARP сильно режет скорость видеотрафика YouTube
GOOGLE_IPS=""
if [[ -n "$GOOGLE_IPS" ]]; then
  ALL_IPS="${TELEGRAM_IPS}, ${GOOGLE_IPS}"
  sed -i "s|^AllowedIPs.*|AllowedIPs = $ALL_IPS|" /etc/wireguard/warp.conf
  systemctl restart wg-quick@warp
fi
EOF
  chmod +x "$CRON_SCRIPT"
  ln -sf "$CRON_SCRIPT" /etc/cron.weekly/warp_update_ips
  
  popd >/dev/null
  rm -rf "$WORK_DIR"

  # Запуск WireGuard интерфейса
  systemctl enable --now wg-quick@warp
  
  if ip link show warp >/dev/null 2>&1; then
    success "Туннель WARP для обхода DPI Telegram успешно настроен и запущен."
  else
    error "Не удалось поднять интерфейс WARP."
  fi
}
