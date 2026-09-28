# Aegis Gateway Design

## Goal and Overview
Aegis Gateway is an enterprise-grade multi-protocol edge gateway and deployment orchestrator for Ubuntu 24.04. It consolidates multiple proxy, VPN, and anti-censorship protocols behind an SNI-multiplexed frontend, providing robust DPI evasion, zero-downtime maintenance, and strict host hardening.

## Core Architecture

### 1. Ingress & SNI Multiplexing
- **HAProxy Frontend (Port 443 TCP)**: Operates at Layer 4 SNI inspection.
  - SNI matching domain A (e.g. proxy domain) -> routed locally to **Caddy** (HTTPS Forward Proxy + Naive/gRPC/WebDAV fallback).
  - SNI matching fake TLS disguise domain (e.g. google.com / cloudflare.com) -> routed to **Teleproxy** (Telegram MTProto Fake-TLS).
  - Unrecognized SNI or direct IP probing -> routed to Caddy fallback / honeypot upstream, returning standard HTTP responses and concealing the gateway services.
- **Port 80 TCP**: Dedicated to HTTP challenges (Let's Encrypt / Certbot standalone or Caddy HTTP-01) and redirect to HTTPS.

### 2. Supported Protocols & Components
- **AmneziaWG**: Modern WireGuard implementation with protocol obfuscation (init packet magic headers, junk packet ranges, and custom under-the-radar packet size limits) designed to resist deep packet inspection (DPI).
- **Caddy (with forwardproxy plugin)**: High-performance HTTPS forward proxy requiring TLS client credentials, serving genuine camouflage static website content to unauthenticated requests.
- **Dumbproxy**: Standalone secure HTTP/HTTPS proxy with user authentication and rate limiting.
- **Teleproxy (MTProto Fake-TLS)**: Native Telegram proxy utilizing 16-byte TLS camouflage secrets.
- **3x-ui / Xray-core**: Optional multi-protocol panel (VLESS, VMess, Trojan, Shadowsocks) with Reality TLS camouflage.
- **Cloudflare WARP (wireguard-go)**: Internal egress tunnel routing Telegram or regional API traffic through Cloudflare edge IP pool to avoid datacenter IP bans.

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
