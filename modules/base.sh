#!/usr/bin/env bash

module_base_install() {
  local packages=(adduser ca-certificates certbot curl fail2ban gnupg jq lsb-release openssl python3 sudo ufw iptables whiptail)
  log "Установка базовых пакетов: ${packages[*]}"
  apt-get update -y
  apt-get install -y --no-install-recommends "${packages[@]}"

  module_base_install_docker

  log "Оптимизация сетевого стека и включение BBR..."
  cat > /etc/sysctl.d/99-vpn-optimization.conf <<EOF
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
EOF
  sysctl -p /etc/sysctl.d/99-vpn-optimization.conf || true
}

module_base_install_docker() {
  if command -v docker &>/dev/null; then
    log "Docker уже установлен ($(docker --version)), пропуск."
    return 0
  fi

  log "Установка Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local arch codename
  arch=$(dpkg --print-architecture)
  codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$arch" "$codename" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  success "Docker Engine установлен и запущен."
}

module_base_check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
      die "This installer targets Ubuntu 24.04 (detected: ${ID:-unknown} ${VERSION_ID:-unknown})."
    fi
  fi
  
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (sudo)."
  fi
}
