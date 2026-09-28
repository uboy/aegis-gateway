# Aegis Gateway Design

## Goal and Overview
Aegis Gateway is an enterprise-grade multi-protocol edge gateway and deployment orchestrator for Ubuntu 24.04. It consolidates multiple secure proxy, VPN, and transport routing services behind a single unified SNI-multiplexed frontend on port 443, providing zero-downtime maintenance, protocol metadata protection, and strict host hardening.

## Core Architecture

### 1. Ingress & SNI Multiplexing
- **HAProxy Frontend (Port 443 TCP)**: Operates at Layer 4 SNI inspection without payload decryption.
  - SNI matching proxy domain (with TLS handshake) -> routed locally to `127.0.0.1:2399` (**mtproxy-tls** Fake-TLS backend).
  - ALPN present without SNI (Telegram Desktop client connecting by IP) -> routed to `127.0.0.1:4431` (**Caddy** terminating TLS -> **tproxy-server** WebSocket relay on `127.0.0.1:8080` -> internal MTProxy RPC on `127.0.0.1:2398`).
  - Connections without TLS handshake (plain secret) -> routed to `127.0.0.1:2398` (**mtproxy** plain backend).
  - SNI matching administrative domain -> routed locally to `127.0.0.1:4430` (**Dumbproxy** HTTPS forward proxy).
  - Unrecognized SNI or direct IP probing -> routed to Caddy honeypot (`127.0.0.1:4431`), serving a valid static website and strict security headers, completely concealing internal services.
- **Port 80 TCP**: Dedicated to HTTP challenges (Let's Encrypt / Certbot standalone or Caddy HTTP-01) and redirect to HTTPS.

### 2. Supported Protocols & Components
- **AmneziaWG**: Modern high-performance WireGuard implementation with protocol header randomization and customizable packet sizes, preventing signature and metadata-based traffic profiling.
- **Telegram Proxy**: Unified stealth setup on port 443 supporting both WebProxy (Telegram Desktop) and Fake-TLS (Telegram Mobile) backed by an isolated local MTProxy daemon.
- **Caddy**: High-performance reverse proxy and static site server serving genuine website content to unauthenticated requests.
- **Dumbproxy**: Standalone secure HTTP/HTTPS proxy with user authentication and rate limiting.
- **3x-ui / Xray-core**: Multi-protocol panel (VLESS Reality, Trojan) using CDN-based camouflage targets and packet padding (`xtls-rprx-vision`), with management access isolated via SSH tunnels.
- **Cloudflare WARP (wireguard-go)**: Internal egress tunnel routing regional API traffic through Cloudflare edge IP pool to avoid datacenter IP restrictions.

### 3. Safe Upgrade Pipeline
- **Pre-flight Health Checks**:
  - Verification of free disk space (minimum 100MB required).
  - Integrity and syntax validation of target configurations (e.g., `caddy validate --config <file>`).
  - Active network connectivity checks to binary release mirrors (GitHub API / direct releases).
- **Atomic Binary Swaps & Rollback**:
  - Binaries are downloaded to temporary staging directories and verified for checksum/execution before replacement.
  - Replacement is performed atomically using `install -m 755` (preventing `ETXTBSY - Text file busy` kernel errors on running executables).
  - Automatic rollback (`_aegis_rollback_binary`) restores previous working binaries and systemd units if health check fails.
- **Automation**:
  - Systemd service (`aegis-upgrade.service`) executed via systemd timer (`aegis-upgrade.timer`) with randomized delays to avoid predictable maintenance spikes.

### 4. Security & Hardening Policy
- **Host Security**:
  - SSH root password login disabled; public key authentication enforced.
  - Custom non-standard SSH port configured with automatic firewall rule synchronization.
  - Fail2Ban integrated with nftables/UFW to mitigate brute-force scanning.
- **State & Idempotency**:
  - Execution state is recorded in `/root/.aegis-vpn.state` with strict `0600` permissions.
  - All installer modules are idempotent: subsequent invocations safely detect existing configuration, preserve persistent keys/certificates, and update only modified layers.
