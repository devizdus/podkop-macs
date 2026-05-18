# OpenWRT — podkop MAC filter (per-device proxy routing)

> Репозиторий: `devizdus/podkop-macs`
> 
> Статус: техническое задание

---

## 1. Проблема

Podkop ([itdoginfo/podkop](https://github.com/itdoginfo/podkop)) — отличный инструмент для маршрутизации трафика на заблокированные ресурсы через прокси/VPN на OpenWRT 24.10. Но у него нет штатного per-device routing: доменные списки (Russia inside, Geoblock и т.д.) применяются ко **всем** устройствам в сети. 

Штатный механизм `Routing Excluded IPs` требует ручного добавления IP каждого устройства, которое **не** должно ходить через прокси. При динамической выдаче DHCP и появлении новых устройств это неудобно.

## 2. Решение

Надстройка над podkop, которая:

- Хранит **белый список MAC-адресов** устройств, которым **разрешено** ходить через прокси
- При каждом изменении DHCP-лизов (устройство подключилось/отключилось) автоматически синхронизирует `Routing Excluded IPs` в podkop: все IP, чей MAC не в белом списке, исключаются из проксирования
- Предоставляет страницу в LuCI для редактирования белого списка MAC-адресов и ручного запуска синхронизации

### Логика работы

```
Устройство подключилось к WiFi
         │
         ▼
   dnsmasq вызывает dhcp-script
         │
         ▼
   podkop-sync-excluded:
   1. Читает /etc/podkop-proxy-macs (белый список MAC)
   2. Читает /tmp/dhcp.leases (все текущие lease)
   3. Сравнивает: IP, чей MAC НЕ в белом списке → excluded
   4. Записывает excluded в uci podkop.@main[0].routing_excluded_ips
   5. Делает podkop reload
```

---

## 3. Структура репозитория

```
podkop-macs/
├── README.md                         # Описание, установка, использование
├── install.sh                        # Скрипт установки
├── uninstall.sh                      # Скрипт удаления с очисткой
├── files/
│   ├── usr/
│   │   └── bin/
│   │       └── podkop-sync-excluded  # Основной скрипт синхронизации
│   └── etc/
│       └── podkop-proxy-macs         # Дефолтный белый список MAC
├── luci/
│   ├── controller/
│   │   └── podkop-macs.lua           # LuCI контроллер
│   ├── view/
│   │   └── podkop_macs.htm           # LuCI шаблон страницы
│   └── po/
│       └── ru/
│           └── podkop_macs.po        # Переводы
└── Makefile                          # (опционально) OpenWRT package
```

---

## 4. Компоненты

### 4.1. Конфигурационный файл `/etc/podkop-proxy-macs`

Простой текстовый файл. Формат:
- Один MAC-адрес на строку (строчные буквы, двоеточия)
- Поддерживаются комментарии: `#`
- Пустые строки игнорируются

```
# Устройства, которые будут ходить через podkop/proxy
aa:bb:cc:dd:ee:ff  # my-laptop
aa:bb:cc:dd:ee:ff  # ещё устройство
```

### 4.2. Скрипт синхронизации `/usr/bin/podkop-sync-excluded`

```sh
#!/bin/sh
# podkop-sync-excluded — синхронизирует Routing Excluded IPs в podkop
# на основе белого списка MAC-адресов и текущих DHCP-лизов.

PROXY_MACS_FILE="/etc/podkop-proxy-macs"
LEASES_FILE="/tmp/dhcp.leases"
PODKOP_SECTION="main"

# Читаем разрешённые MAC (пропускаем комментарии и пустые строки)
PROXY_MACS=$(grep -v '^#' "$PROXY_MACS_FILE" 2>/dev/null | grep -v '^$' | awk '{print $1}' | tr '[:upper:]' '[:lower:]')

# Если белый список пуст — включаем прокси для всех (очищаем excluded)
if [ -z "$PROXY_MACS" ]; then
    uci delete podkop.@"$PODKOP_SECTION"[0].routing_excluded_ips 2>/dev/null
    uci commit podkop
    /etc/init.d/podkop reload 2>/dev/null || /usr/bin/podkop reload 2>/dev/null
    logger -t podkop-sync "Proxy enabled for ALL devices (whitelist empty)"
    exit 0
fi

# Собираем IP, чьи MAC НЕ в белом списке
EXCLUDED_IPS=""
while read -r expiry mac ip hostname rest; do
    [ -z "$ip" ] && continue
    mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    FOUND=0
    for proxy_mac in $PROXY_MACS; do
        if [ "$mac_lower" = "$proxy_mac" ]; then
            FOUND=1
            break
        fi
    done
    if [ "$FOUND" = "0" ]; then
        EXCLUDED_IPS="$EXCLUDED_IPS $ip"
    fi
done < "$LEASES_FILE"

# Обновляем podkop: очищаем старый список, добавляем новый
uci delete podkop.@"$PODKOP_SECTION"[0].routing_excluded_ips 2>/dev/null
for ip in $EXCLUDED_IPS; do
    uci add_list podkop.@"$PODKOP_SECTION"[0].routing_excluded_ips="$ip"
done
uci commit podkop

# Применяем
/etc/init.d/podkop reload 2>/dev/null || /usr/bin/podkop reload 2>/dev/null

logger -t podkop-sync "Excluded IPs: $(echo $EXCLUDED_IPS | wc -w) devices"
```

**Требования к скрипту:**
- ✅ Выполняется без ошибок при отсутствии `/etc/podkop-proxy-macs` (все устройства проксируются)
- ✅ Выполняется без ошибок при отсутствии `/tmp/dhcp.leases`
- ✅ Выполняется без ошибок если podkop не запущен
- ✅ Работает с пустым белым списком (все устройства проксируются — excluded очищается)
- ✅ Регистронезависимое сравнение MAC-адресов
- ✅ Пишет в syslog (`logger -t podkop-sync`)
- ✅ Атомарное обновление uci (delete → add_list → commit → reload)

### 4.3. Страница LuCI

**Путь в интерфейсе:** Services → Podkop MACs

**Элементы страницы:**

| Секция | Содержание |
|--------|-----------|
| Заголовок | Podkop — фильтр по MAC-адресам |
| Описание | «Только устройства с MAC-адресами из списка ниже будут использовать прокси. Все остальные исключаются автоматически.» |
| Current leases | Таблица: MAC, IP, Hostname — все устройства из `/tmp/dhcp.leases`. Только для чтения, для справки |
| Allowed MACs | `<textarea>` с содержимым `/etc/podkop-proxy-macs`. Кнопка **Сохранить** |
| Excluded IPs | Актуальный список исключённых IP из `uci get podkop.@main[0].routing_excluded_ips`. Только для чтения |
| Sync now | Кнопка ручного запуска синхронизации |

**Контроллер (`/usr/lib/lua/luci/controller/podkop-macs.lua`):**

```lua
module("luci.controller.podkop-macs", package.seeall)

function index()
    entry({"admin", "services", "podkop_macs"}, 
          template("podkop_macs"), 
          _("Podkop MACs"), 80)
    entry({"admin", "services", "podkop_macs", "save"}, 
          call("action_save"))
    entry({"admin", "services", "podkop_macs", "sync"}, 
          call("action_sync"))
end

function action_save()
    local macs = luci.http.formvalue("macs")
    local file = io.open("/etc/podkop-proxy-macs", "w")
    if file then
        file:write(macs)
        file:close()
    end
    luci.http.redirect(luci.dispatcher.build_url("admin/services/podkop_macs"))
end

function action_sync()
    os.execute("/usr/bin/podkop-sync-excluded &")
    luci.http.redirect(luci.dispatcher.build_url("admin/services/podkop_macs"))
end
```

**Шаблон (`/usr/lib/lua/luci/view/podkop_macs.htm`):**

Стандартный LuCI-шаблон с `<%+header%>`/`<%+footer%>`. Три секции, описанные выше. Текстarea для MAC, pre-блоки для leases и excluded IPs.

### 4.4. Автоматическая синхронизация

**Вариант 1 (основной): dnsmasq dhcp-script**

В `/etc/dnsmasq.conf` добавляется:
```
dhcp-script=/usr/bin/podkop-sync-excluded
```

Dnsmasq вызывает скрипт при каждом событии DHCP (выдача, обновление, освобождение lease).

**Вариант 2 (подстраховка): cron**

В `/etc/crontabs/root` добавляется:
```
*/5 * * * * /usr/bin/podkop-sync-excluded
```

---

## 5. Скрипт установки (`install.sh`)

```sh
#!/bin/sh
# install.sh — установка podkop-macs
# Требования: OpenWRT 24.10, установленный podkop

set -e

echo "=== podkop-macs install ==="

# Проверка podkop
if ! which podkop > /dev/null 2>&1; then
    echo "ERROR: podkop not found. Install podkop first:"
    echo "  sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)"
    exit 1
fi

echo "1. Installing sync script..."
cp files/usr/bin/podkop-sync-excluded /usr/bin/podkop-sync-excluded
chmod +x /usr/bin/podkop-sync-excluded

echo "2. Installing default MAC whitelist (empty)..."
if [ ! -f /etc/podkop-proxy-macs ]; then
    cp files/etc/podkop-proxy-macs /etc/podkop-proxy-macs
fi

echo "3. Installing LuCI page..."
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/view/podkop_macs
cp luci/controller/podkop-macs.lua /usr/lib/lua/luci/controller/podkop-macs.lua
cp luci/view/podkop_macs.htm /usr/lib/lua/luci/view/podkop_macs.htm

# Переводы (опционально)
if [ -d luci/po/ru ]; then
    mkdir -p /usr/lib/lua/luci/po/ru
    cat luci/po/ru/podkop_macs.po >> /usr/lib/lua/luci/po/ru/podkop-macs.po 2>/dev/null || \
        cp luci/po/ru/podkop_macs.po /usr/lib/lua/luci/po/ru/podkop-macs.po
fi

echo "4. Configuring dnsmasq auto-sync..."
if ! grep -q "podkop-sync-excluded" /etc/dnsmasq.conf 2>/dev/null; then
    echo "dhcp-script=/usr/bin/podkop-sync-excluded" >> /etc/dnsmasq.conf
fi

echo "5. Adding cron fallback..."
if ! grep -q "podkop-sync-excluded" /etc/crontabs/root 2>/dev/null; then
    echo "*/5 * * * * /usr/bin/podkop-sync-excluded" >> /etc/crontabs/root
fi

echo "6. Restarting services..."
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/dnsmasq restart
/etc/init.d/cron restart 2>/dev/null

echo "7. Running initial sync..."
/usr/bin/podkop-sync-excluded

echo ""
echo "=== Done ==="
echo "LuCI page: Services → Podkop MACs"
echo "Config file: /etc/podkop-proxy-macs"
```

**Установка одной командой:**
```sh
wget -O - https://raw.githubusercontent.com/devizdus/podkop-macs/main/install.sh | sh
```

---

## 6. Скрипт удаления (`uninstall.sh`)

```sh
#!/bin/sh
# uninstall.sh — полное удаление podkop-macs с очисткой всех следов

set -e

echo "=== podkop-macs uninstall ==="

echo "1. Stopping podkop (to clean nftables)..."
/etc/init.d/podkop stop 2>/dev/null || true

echo "2. Cleaning Routing Excluded IPs in podkop config..."
uci delete podkop.@main[0].routing_excluded_ips 2>/dev/null || true
uci commit podkop

echo "3. Removing sync script..."
rm -f /usr/bin/podkop-sync-excluded

echo "4. Removing MAC whitelist..."
rm -f /etc/podkop-proxy-macs

echo "5. Removing LuCI page..."
rm -f /usr/lib/lua/luci/controller/podkop-macs.lua
rm -f /usr/lib/lua/luci/view/podkop_macs.htm

echo "6. Removing translations..."
rm -f /usr/lib/lua/luci/po/ru/podkop-macs.po

echo "7. Removing dnsmasq hook..."
sed -i '/podkop-sync-excluded/d' /etc/dnsmasq.conf

echo "8. Removing cron job..."
sed -i '/podkop-sync-excluded/d' /etc/crontabs/root
/etc/init.d/cron restart 2>/dev/null || true

echo "9. Restarting services..."
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/dnsmasq restart

echo "10. Starting podkop..."
/etc/init.d/podkop start 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "podkop-macs полностью удалён."
echo "Podkop запущен без фильтрации (все устройства проксируются)."
```

**Что делает uninstall:**
- Останавливает podkop
- Очищает `routing_excluded_ips` в конфиге podkop (возвращает проксирование для всех)
- Удаляет все файлы: скрипт, конфиг, LuCI-страницу, переводы
- Убирает строку из `/etc/dnsmasq.conf`
- Убирает cron-задачу
- Сбрасывает кэш LuCI
- Перезапускает podkop в исходном состоянии

---

## 7. Инструкция по использованию

### Начальная настройка

1. Установить podkop: `sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)`
2. Настроить секцию Main с VLESS и списками (Russia inside)
3. Установить podkop-macs: `sh <(wget -O - https://raw.githubusercontent.com/devizdus/podkop-macs/main/install.sh)`
4. Зайти в LuCI → Services → Podkop MACs
5. Скопировать MAC нужного устройства из таблицы Current leases
6. Вставить его в поле Allowed MACs, сохранить
7. Нажать Sync now

### Повседневное использование

- Подключил новое устройство → оно автоматически исключено из прокси
- Хочешь чтобы новое устройство ходило через прокси → добавил MAC в LuCI → Sync now
- Хочешь убрать устройство из прокси → удалил MAC из списка → Sync now

### Пустой белый список

Если в `/etc/podkop-proxy-macs` нет ни одного MAC — **все** устройства проксируются (поведение podkop по умолчанию). Это защита от случайной блокировки прокси для всех.

---

## 8. Зависимости

| Пакет | Назначение | Обязателен |
|-------|-----------|------------|
| `podkop` (itdoginfo) | Основной прокси-пакет | ✅ |
| `luci` | Веб-интерфейс | ✅ |
| `dnsmasq` (или `dnsmasq-full`) | DHCP-сервер + dhcp-script | ✅ |
| `cron` / `busybox-crond` | Подстраховочная синхронизация | ⚠️ (рекомендуется) |
| `uci` | Управление конфигурацией | ✅ (есть в базовой системе) |

---

## 9. Ограничения

- Работает только в паре с podkop. Другие прокси-пакеты (PassWall2, OpenClash) не поддерживаются
- Требует dnsmasq — если используется odhcpd, dhcp-script не сработает (останется только cron)
- При очень большом количестве устройств (50+) reload podkop может занимать несколько секунд
- Не поддерживает IPv6 (только IPv4 DHCP-лизы)
- Привязка к MAC, а не к статическому IP — если устройство меняет MAC (рандомизация), оно будет исключено

---

## 10. Тестирование

### Сценарий 1: базовый

1. Белый список: `aa:bb:cc:dd:ee:ff`
2. В DHCP есть устройство с этим MAC → его IP **не** в excluded
3. В DHCP есть устройство с другим MAC → его IP в excluded
4. ✅ Прокси работает только для первого устройства

### Сценарий 2: пустой белый список

1. Белый список пуст
2. `routing_excluded_ips` очищен
3. ✅ Все устройства проксируются

### Сценарий 3: нет файла с MAC

1. `/etc/podkop-proxy-macs` отсутствует
2. Скрипт не падает, записывает в лог «enabled for ALL»
3. ✅ Все устройства проксируются

### Сценарий 4: новое устройство

1. Подключилось устройство с MAC не из белого списка
2. dnsmasq дёрнул dhcp-script
3. Устройство автоматически добавлено в excluded
4. ✅ Устройство ходит напрямую

---

## 11. Дальнейшее развитие (бэклог)

- [ ] Поддержка IPv6 (DHCPv6 leases)
- [ ] Поддержка hostname в белом списке (не только MAC)
- [ ] Интеграция с другими прокси-пакетами (PassWall2, OpenClash)
- [ ] Статистика: сколько трафика сэкономил excluded
- [ ] Возможность исключать из прокси только определённые порты/протоколы для excluded-устройств
- [ ] WebSocket-уведомления в LuCI при изменении списка
