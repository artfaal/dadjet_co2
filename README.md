# CO2 Monitor — Raspberry Pi 4B + Docker

Мониторинг CO2 датчика **Holtek USB-zyTemp (04d9:a052)** на Raspberry Pi 4B.
Данные публикуются в **Prometheus Pushgateway** (основной) или **MQTT**.

## Архитектура

```
CO2 датчик (USB)
      │
      ▼
┌─────────────────────────────────────────────┐
│  Raspberry Pi 4B                            │
│                                             │
│  ┌──────────────┐   Docker internal net     │
│  │   co2mond    │ ──────────────────────►   │
│  │ :9999/metrics│    ┌──────────────────┐   │
│  └──────────────┘    │    co2push       │   │
│        ▲  USB        │  (Pushgateway /  │   │
│        │             │     MQTT)        │   │
│  /dev/bus/usb        └──────────────────┘   │
└─────────────────────────────────────────────┘
         │                      │
         ▼                      ▼
  [pushgateway.artfaal.ru]  [mqtt broker]
  [prometheus → grafana]
```

## Требования

- Raspberry Pi 4B (aarch64) с Raspberry Pi OS / Debian
- Docker ≥ 20.10, Docker Compose ≥ v2
- CO2 датчик Holtek USB-zyTemp (04d9:a052) — **data кабель** (не зарядный!)
- Prometheus Pushgateway или MQTT брокер

## Быстрый старт

```bash
# 1. Клонировать репозиторий вместе с submodule
git clone --recurse-submodules https://github.com/artfaal/dadjet_co2.git
cd dadjet_co2

# 2. Создать .env и настроить
cp .env.example .env
nano .env

# 3. Установить udev rules для датчика (один раз)
sudo cp co2mon/udevrules/99-co2mon.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger

# 4. Собрать образы и запустить
docker compose build
docker compose up -d

# 5. Проверить
docker compose logs -f
```

## Установка подробно

### 1. Docker (если не установлен)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 2. Клонирование репозитория

```bash
git clone --recurse-submodules https://github.com/artfaal/dadjet_co2.git ~/dadjet_co2
cd ~/dadjet_co2
```

> Флаг `--recurse-submodules` автоматически клонирует `co2mon/` из
> [github.com/dmage/co2mon](https://github.com/dmage/co2mon).

Если репозиторий уже склонирован без submodule:
```bash
git submodule update --init --recursive
```

### 3. Настройка переменных окружения

```bash
cp .env.example .env
nano .env
```

```env
# --- Prometheus Pushgateway ---
PUSHGATEWAY_URL=https://pushgateway.example.com
JOB_NAME=co2monitor
INSTANCE_NAME=home

# --- MQTT (опционально) ---
MQTT_HOST=mqtt.example.com
MQTT_PORT=1883
MQTT_USER=your_username
MQTT_PASS=your_password
MQTT_TOPIC_PREFIX=home/sensors/co2monitor

# Push interval in seconds
PUSH_INTERVAL=30
```

### 4. udev rules для USB-датчика

Нужно сделать **один раз на хосте**, чтобы Docker-контейнер имел доступ к USB HID:

```bash
sudo cp co2mon/udevrules/99-co2mon.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

После подключения датчика убедитесь, что он виден:
```bash
lsusb | grep 04d9
# Bus 001 Device 003: ID 04d9:a052 Holtek Semiconductor, Inc. USB-zyTemp
```

> **Важно:** используйте data-кабель (не кабель только для зарядки).
> При подключении кабеля-зарядки датчик светится, но в `lsusb` не появляется.

### 5. Сборка и запуск

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

## Образы Docker

Оба образа построены на **Alpine Linux 3.21** — минимальный размер:

| Образ | Содержимое | Размер |
|-------|-----------|--------|
| `dadjet-co2mond` | `co2mond` + `hidapi` + `libusb` | ~14 MB |
| `dadjet-co2push` | `bash` + `curl` + `mosquitto_pub` | ~26 MB |

Сборка `co2mond` происходит из исходников (multi-stage Dockerfile). Логи ограничены
5 MB на файл, 3 файла ротации.

## Выбор метода публикации

По умолчанию запускается **Pushgateway**-публикатор (`push_co2_data.sh`).

Для переключения на **MQTT** — изменить в `docker-compose.yml`:
```yaml
    command: ["/app/push_co2_mqtt.sh"]
```

## Управление

```bash
# Статус контейнеров
docker compose ps

# Логи в реальном времени
docker compose logs -f

# Только co2mond или co2push
docker compose logs -f co2mond
docker compose logs -f co2push

# Перезапуск
docker compose restart

# Остановить
docker compose down

# Пересобрать и перезапустить (после изменений)
docker compose up -d --build
```

## Проверка работы

```bash
# Метрики с датчика (внутри RPi)
curl http://localhost:9999/metrics   # работает только если co2mond слушает на хосту

# Из co2push контейнера (правильный способ)
docker exec co2push curl -s http://co2mond:9999/metrics

# Проверить Pushgateway
curl https://pushgateway.example.com/metrics | grep co2
```

Ожидаемый вывод `/metrics`:
```
# TYPE co2mon_co2_ppm gauge
co2mon_co2_ppm 831
# TYPE co2mon_temp_celsius gauge
co2mon_temp_celsius 24.725
```

Ожидаемые логи при нормальной работе:
```
co2mond  | Tamb    24.7250
co2mond  | CntR    831
co2push  | [2026-02-22 10:51:00] SUCCESS: CO2=831 ppm, Temp=24.7250°C
```

## Настройка сервера (Docker Compose)

### Prometheus + Pushgateway

```yaml
services:
  pushgateway:
    image: prom/pushgateway
    container_name: pushgateway
    restart: unless-stopped
    ports:
      - "9091:9091"
    networks:
      - monitoring

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"
    networks:
      - monitoring

volumes:
  prometheus-data:

networks:
  monitoring:
```

`prometheus.yml`:
```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ['pushgateway:9091']
```

### MQTT Broker (Mosquitto)

```yaml
services:
  mosquitto:
    image: eclipse-mosquitto
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto.conf:/mosquitto/config/mosquitto.conf
      - mosquitto-data:/mosquitto/data

volumes:
  mosquitto-data:
```

## Устранение неполадок

### Датчик не виден в lsusb

```bash
lsusb | grep 04d9
```

- Проверьте, что используется **data-кабель**, а не кабель только для зарядки
- Попробуйте другой USB-порт на RPi (RPi 4 имеет 2x USB2 и 2x USB3)
- Переподключите датчик после установки udev rules

### co2mond: `hid_open: error`

Нормально до подключения датчика. После подключения — перезапустите контейнер:
```bash
docker compose restart co2mond
```

### co2push: `WARNING: No metrics found`

co2mond запущен, но датчик ещё не прочитал данные (первые ~10 секунд после подключения).
Если предупреждение продолжается — проверьте логи co2mond.

### Данные не доходят до Pushgateway

```bash
# Проверьте доступность
curl -s -o /dev/null -w "%{http_code}" https://pushgateway.example.com/metrics

# Проверьте .env
cat .env | grep PUSHGATEWAY
```

## Файлы проекта

```
dadjet_co2/
├── Dockerfile               # Multi-stage Alpine: co2mond + co2push
├── docker-compose.yml       # Оркестрация сервисов + лог-ротация
├── .env.example             # Шаблон конфигурации
├── push_co2_data.sh         # Публикатор → Prometheus Pushgateway (дефолт)
├── push_co2_mqtt.sh         # Публикатор → MQTT broker
├── co2mon/                  # Git submodule (github.com/dmage/co2mon)
│   ├── co2mond/             # Daemon: считывает USB HID, экспортирует метрики
│   ├── libco2mon/           # Библиотека: HID-протокол датчика Holtek
│   └── udevrules/           # udev rules для USB-устройства (04d9:a052)
└── README.md                # Эта инструкция
```

## Безопасность

- Файл `.env` с секретами исключён из git через `.gitignore`
- `co2push` запускается с `no-new-privileges`
- `privileged: true` для `co2mond` нужен для USB HID доступа — при желании
  можно заменить на точечный `devices` mount после настройки udev rules
- Используйте HTTPS для Pushgateway
- Контейнеры изолированы во внутренней сети `co2net`, порты наружу не проброшены
