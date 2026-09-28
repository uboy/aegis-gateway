# Архитектура проекта Aegis Gateway

## Основная концепция
Aegis Gateway — это универсальный модульный edge-шлюз и установщик для Ubuntu 24.04, обеспечивающий комплексную систему маршрутизации трафика, обхода блокировок (DPI evasion), обратных прокси и безопасного управления сервисами.

## Структура директорий
```text
.
├── install.sh            # Главный исполняемый файл (интерактивный оркестратор)
├── lib/                  # Ядро: общие функции и библиотеки
│   ├── common.sh         # Логирование, обработка ошибок, утилиты
│   ├── state.sh          # Управление состоянием установки (/root/.aegis-vpn.state)
│   ├── utils.sh          # Валидация IP/портов, генерация паролей
│   ├── ui.sh             # Интерактивное меню (whiptail / console)
│   ├── cert.sh           # Управление SSL-сертификатами (Let's Encrypt / Certbot)
│   ├── firewall.sh       # Управление правилами UFW
│   ├── xui_api.sh        # Взаимодействие с API панели 3x-ui
│   └── upgrade.sh        # Движок безопасного обновления (pre-flight, atomic swap, rollback)
├── modules/              # Независимые модули установки компонентов
│   ├── base.sh           # Системные пакеты, базовая настройка ОС
│   ├── hardening.sh      # Hardening: SSH (non-standard port, no root), Fail2Ban (nftables)
│   ├── xui.sh            # Установка 3x-ui (Docker, VLESS/Reality)
│   ├── amnezia.sh        # AmneziaWG (нативный DKMS модуль, защита от DPI)
│   ├── dumbproxy.sh      # Защищенный HTTP/HTTPS прокси-сервер
│   ├── mtproto.sh        # Telegram MTProto Fake-TLS прокси (Teleproxy)
│   ├── tproxy_server.sh  # HAProxy SNI multiplexer + Caddy reverse proxy
│   ├── openvpn.sh        # OpenVPN сервер
│   ├── openconnect.sh    # OpenConnect (Cisco AnyConnect / ocserv)
│   └── warp_telegram.sh  # Cloudflare WARP туннель для Telegram / Google
├── scripts/              # Скрипты обслуживания
│   └── upgrade-services.sh # CLI оркестратор безопасного обновления сервисов
├── systemd/              # Юниты systemd
│   ├── aegis-upgrade.service # Сервис автоматического обновления
│   └── aegis-upgrade.timer   # Еженедельный таймер обновления
└── docs/                 # Документация и ранбуки
    └── mtproto_runbook.md
```

## Жизненный цикл (Execution Flow)
1. **Инициализация**: Запуск `install.sh`. Подгрузка библиотек из `lib/`.
2. **Загрузка состояния**: `load_install_state` читает сохраненные данные из `/root/.aegis-vpn.state` (если запуск не первый).
3. **UI / Промпты**: Скрипт запрашивает параметры компонентов, домены, порты, учетные данные через консольный или whiptail UI.
4. **Сохранение состояния**: Выбор и введенные данные сохраняются в `/root/.aegis-vpn.state`.
5. **Pre-flight Check**: Валидация входных параметров (домены, доступность портов, конфликты).
6. **Базовая настройка**: `modules/base.sh` (системные пакеты, Docker, тюнинг ядра) -> `modules/hardening.sh` (SSH, Fail2Ban).
7. **Исполнение модулей**: Поочередный вызов `module_<name>_install` и `module_<name>_configure` для выбранных компонентов.
8. **Пост-конфигурация**: Настройка UFW, проверка сервисов, генерация финального отчета с доступами.

## Стандарты модулей
Каждый модуль должен экспортировать 2-3 основные функции:
- `module_<name>_install` — скачивание пакетов/образов, раскладка файлов.
- `module_<name>_configure` — применение конфигурации, генерация ключей/сертификатов.
- *(Опционально)* `module_<name>_status` — проверка работоспособности.

Модули не должны напрямую менять настройки других модулей. Для открытия портов они вызывают функцию из `lib/firewall.sh`.
