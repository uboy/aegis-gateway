# Aegis Gateway

Универсальный модульный edge-шлюз и установщик для Ubuntu 24.04, позволяющий развернуть комплексную систему обхода блокировок, обратных прокси и безопасного управления сервисами.

## Возможности
- **3x-ui Panel**: Удобное управление Xray (VLESS, Trojan, Reality).
- **OpenVPN**: Классический VPN (UDP/1194).
- **OpenConnect (ocserv)**: Имитация Cisco AnyConnect (TCP/4443).
- **AmneziaWG**: Современный протокол с защитой от DPI (UDP/39442).
- **MTProto**: Telegram-native прокси для обхода блокировок (TCP/8443 по умолчанию, Reality остаётся на 443).
- **Dumbproxy & Caddy**: Защищенные HTTP/HTTPS прокси и реверс-прокси с маскировкой.
- **HAProxy Ingress**: Интеллектуальный роутер TLS SNI на порту 443.
- **Security Hardening**: Автоматическая настройка SSH (non-standard port, no root), Fail2Ban (nftables) и UFW.
- **Safe Upgrade Pipeline**: Автоматическое безопасное обновление APT и non-APT служб (Caddy, dumbproxy) с pre-flight проверками, atomic swap и автоматическим rollback при сбое health-check.
- **Интерактивный UI**: Выбор компонентов через удобные меню.

## Использование
1. Скачайте проект.
2. Запустите основной скрипт от имени root:
   ```bash
   sudo bash install.sh
   ```
3. Следуйте инструкциям на экране и выберите нужные компоненты, включая `OpenVPN` и `MTProto`, в интерактивном меню.

## MTProto для Telegram
- Для Telegram предпочтительнее использовать `MTProto`, а не обычный `HTTP`-прокси.
- `MTProto` в этом проекте ставится нативно из [`teleproxy/teleproxy`](https://github.com/teleproxy/teleproxy) (Fake-TLS, без Docker); подробности и известные ограничения — в `docs/mtproto_runbook.md`.
- Установщик задаёт порт (default `8443`, Reality занимает `443`) и отдельным экраном — домен маскировки Fake-TLS, генерирует `ee`-секрет и показывает готовую ссылку `tg://proxy?...` в финальном отчёте.
- MTProto — best-effort ingress, а не гарантированный обход блокировок; порт и домен маскировки снижают конфликтность/заметность, но не заменяют полевую проверку с реальным Telegram-клиентом.
- Оператор прокси не получает содержимое сообщений, но видит IP-адрес клиента и время подключений, поэтому использовать стоит только доверенный узел.

## Поведение панели 3x-ui (важно)
- При включенном `Hardening` панель **не публикуется в интернет** — это штатный и безопасный режим.
- Доступ к панели выполняется через SSH-туннель.
- Потеря SSH-туннеля/SSH-сессии выглядит как "панель недоступна", даже если контейнер `3x-ui` работает нормально.

Пример туннеля:
```bash
ssh -N -L 2053:127.0.0.1:2053 <user>@<server> -p <ssh_port>
```

## Диагностика отвалов клиентов 3x-ui
Если отваливаются именно клиенты (а не веб-панель), сначала отделите проблему доступа к панели от проблемы `xray`/inbound:

```bash
docker inspect 3x-ui --format 'status={{.State.Status}} restart={{.RestartCount}} started={{.State.StartedAt}}'
docker logs 3x-ui --since 2h --timestamps | tail -n 300
journalctl -u docker --since "2 hours ago" --no-pager | tail -n 300
ss -lntp | grep -E ':2053|:443'
ufw status numbered
```

Что проверять в логах:
- `xray`, `reality`, `tls`, `handshake`, `timeout`, `killed`, `oom`, `panic`, `fatal`.

## Примечание по Reality target/SNI
- Для стабильности Reality обычно лучше использовать согласованную пару `dest` и `serverNames` (один и тот же хост-профиль).
- По умолчанию авто-создание использует совместимый профиль:
  - `dest=google.com:443`
  - `serverNames=[\"google.com\"]`
  - `flow=\"\"` (пустой, без принудительного `xtls-rprx-vision`)
- При необходимости можно переопределить через переменные окружения:
  - `REALITY_DEST`
  - `REALITY_SERVER_NAME`
  - `REALITY_FLOW`

## Безопасное обновление сервисов (Safe Upgrade Pipeline)
Aegis Gateway включает встроенный конвейер обновления системы и прокси-служб с предпроверками (pre-flight checks), атомарной заменой бинарников и автоматическим откатом (rollback) при сбоях:
```bash
# Проверка доступных обновлений без применения (dry-run)
sudo ./scripts/upgrade-services.sh --check

# Обновление всех компонентов (APT, Caddy, dumbproxy)
sudo ./scripts/upgrade-services.sh --all

# Обновление отдельного компонента
sudo ./scripts/upgrade-services.sh --service dumbproxy
```
Конвейер автоматически запускается еженедельно по таймеру `aegis-upgrade.timer` (воскресенье, 04:30).

## Структура проекта
- `install.sh` — главный оркестратор установки.
- `lib/` — библиотеки (API, UI, State, Utils, Upgrade).
- `modules/` — независимые модули установки конкретных сервисов.
- `scripts/` — утилиты обслуживания и оркестратор обновлений (`upgrade-services.sh`).
- `systemd/` — юниты systemd (`aegis-upgrade.service`, `aegis-upgrade.timer`).

## Системные требования
- ОС: Ubuntu 24.04 (Noble Numbat).
- Права root.
- Свободные порты для выбранных сервисов.
