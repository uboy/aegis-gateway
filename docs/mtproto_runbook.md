# MTProto Proxy (Teleproxy): runbook

Пути и порты из установщика Aegis Gateway. Используется **Teleproxy v4+** — C-реализация MTProto прокси с продвинутой защитой от DPI, актуальной на 2026 год.

> **Почему не mtg?** В июне 2026 массовая блокировка MTProto Fake-TLS в РФ по TLS-fingerprint (JA3)
> задела mtg наравне с другими реализациями. Teleproxy использует fingerprint Chrome TLS 1.3,
> MSS-clamp и ServerHello emulation. **Важно:** проект mtg тоже получил апстрим-фикс (v2.2.8) для
> того же JA3-паттерна — заявление о том, что mtg "сломан навсегда", не подтверждено и требует
> периодической перепроверки, а не считается фактом раз и навсегда.

| Переменная | Путь / значение по умолчанию |
|---|---|
| Бинарник | `/opt/mtproxy/teleproxy` |
| Конфиг | `/etc/mtproxy/config.toml` |
| Сервис | `mtproxy.service` |
| Порт прокси | задаётся в установщике (default `8443`; Reality занимает `443`) |
| Домен маскировки | задаётся в установщике (`MTPROXY_DOMAIN`, отдельный шаг после портов) |
| Версия Teleproxy | закреплена в коде (`MTPROXY_TELEPROXY_VERSION`, default `v4.15.0`) |

## Установка/обновление: pin, checksum, атомарная замена, откат

Установщик **не** качает "latest" — версия закреплена (`MTPROXY_TELEPROXY_VERSION`). Каждая
установка/обновление:
1. Скачивает бинарник и `SHA256SUMS` закреплённого релиза во временный каталог.
2. Проверяет SHA-256 скачанного бинарника против `SHA256SUMS` — при несовпадении установка
   прерывается, ничего рабочего не тронуто.
3. Прогоняет smoke-test (`generate-secret`) на ещё не подключённом бинарнике.
4. Только после этого делает резервную копию текущей установки (`/opt/.mtproxy-rollback-*`) и
   атомарно подключает новый бинарник.
5. После рестарта проверяется не только `systemctl is-active`, но и реальный listening socket
   (`ss`) на эффективном порту.
6. Если сервис не поднялся или не слушает порт — установщик автоматически откатывает бинарник,
   конфиг и unit-файл к резервной копии и перезапускает сервис.

---

## 1. Первая установка

```bash
sudo bash install.sh
```

В меню checklist выбрать **MTProto** (пробел), ввести порт (default `8443`), затем домен
маскировки Fake-TLS (default `www.google.com`, отдельный экран — **не** домен этого сервера,
иначе получится circular-probe, раскрывающий прокси). После установки прокси работает в режиме:
- **Fake-TLS (direct mode)**: трафик маскируется под HTTPS к настоящему сайту
- **MSS clamp** включён по умолчанию: фрагментирует TCP-пакеты, ломая DPI-реассемблинг ТСПУ
- **Chrome TLS 1.3 fingerprint**: JA3 неотличим от Chrome

Если явно выбран порт `<1024` (например `443` на отдельном IP без Reality), установщик добавляет
`AmbientCapabilities=CAP_NET_BIND_SERVICE` в юнит — без этого непривилегированный сервис не может
слушать привилегированный порт.

В финальном отчёте будет:
```
Сервер:   example.com:8443
Секрет:   ee... (hex)
Ссылка:   tg://proxy?server=example.com&port=8443&secret=ee...
```

---

## 2. Где взять tg://proxy ссылку после установки

```bash
grep MTPROXY_SECRET /root/.aegis-vpn.state | cut -d= -f2 | base64 -d
```

Собираем ссылку вручную:
```
tg://proxy?server=<DOMAIN>&port=<PORT>&secret=<MTPROXY_SECRET>
```

---

## 3. Управление секретами

Конфиг `/etc/mtproxy/config.toml`:

```toml
port = 8443
direct = true
domain = "www.google.com"

[[secret]]
key = "YOUR_32_HEX_KEY"
```

Ротация ключа происходит **только** при смене `domain =`: если домен не менялся, установщик
переиспользует существующий секрет как есть; при реальной смене домена генерируется новый ключ
(старые клиентские ссылки при этом перестают работать — обновите их).

Поле `key` — 16-байтовый ключ в hex (32 символа). **Не** полный ee-секрет.
Полный ee-секрет для Telegram клиента: `ee{key}{hex_encoded_domain}`.

### Генерировать новый секрет вручную:
```bash
# Генерирует сразу ee-секрет и key для конфига
/opt/mtproxy/teleproxy generate-secret www.google.com
```

Вывод:
```
ee56f48cd7017713dbec4d35c3c37b10e5676f6f676c652e636f6d   ← для tg:// ссылки
Secret for -S:  56f48cd7017713dbec4d35c3c37b10e5             ← для config.toml key
Domain:         www.google.com
```

### Смена секрета или порта:
1. Отредактируйте конфиг:
```bash
nano /etc/mtproxy/config.toml
```
2. Reload без разрыва соединений:
```bash
kill -HUP $(systemctl show -p MainPID mtproxy | cut -d= -f2)
```
Или полный перезапуск:
```bash
systemctl restart mtproxy
```

---

## 4. Выбор маскировочного домена

Домен `www.google.com` работает, но если ТСПУ заблокирует его — смените на другой:

```bash
# Хорошие варианты (не в блэклисте ТСПУ, популярны, HTTPS 443):
/opt/mtproxy/teleproxy generate-secret www.cloudflare.com
/opt/mtproxy/teleproxy generate-secret www.amazon.com
/opt/mtproxy/teleproxy generate-secret static.cdninstagram.com
```

Обновите `domain =` в конфиге и `key =` на новое значение "Secret for -S". Перезапустите сервис.
Клиентскую ссылку `tg://` нужно обновить на новый ee-секрет.

---

## 5. Мониторинг и диагностика

```bash
# Статус сервиса
systemctl status mtproxy

# Логи в реальном времени
journalctl -u mtproxy -f

# Проверка, что порт слушается
ss -tlnp | grep teleproxy

# Версия и компилятор
/opt/mtproxy/teleproxy 2>&1 | head -1

# HTTP stats (если не менял stats_port, недоступен снаружи)
curl -s http://127.0.0.1:8888/ 2>/dev/null | head -20
```

---

## 6. Быстрая проверка после установки

```bash
systemctl is-active mtproxy    # должно быть: active
ss -tlnp | grep teleproxy      # должен слушать PORT
```

Открываем ссылку `tg://proxy?...` в Telegram → появится диалог «Подключиться к прокси».

---

## 7. Ключевые отличия от mtg

| Функция | mtg v2 | Teleproxy |
|---|---|---|
| TLS fingerprint | Generic | Chrome TLS 1.3 (JA3 = Chrome) |
| MSS clamp (DPI bypass) | Нет | Да (по умолчанию) |
| ServerHello emulation | Нет | Да (live probe) |
| Dynamic Record Sizing | Частично | Да |
| Статус в РФ (2026) | Задет JA3-блокировкой; апстрим выпустил фикс (v2.2.8) | Не тестировался независимо в РФ — требует полевой проверки |
| Язык реализации | Go | C |
