# CO2 Monitor — Raspberry Pi 4B + Docker

Мониторинг CO2 датчика **Holtek USB-zyTemp (04d9:a052)** на Raspberry Pi 4B.
Данные публикуются в **MQTT** или **Prometheus Pushgateway**.

## Архитектура

```
CO2 датчик (USB)
      │
      ▼
┌─────────────────────────────────────────────┐
│  Raspberry Pi 4B                            │
│                                             │
│  ┌──────────────┐    internal Docker net    │
│  │   co2mond    │ ──────────────────────►   │
│  │  :9999/metrics│                          │
│  └──────────────┘    ┌──────────────────┐   │
│        ▲  USB        │    co2push       │   │
│        │             │  (MQTT / Push-   │   │
│  /dev/bus/usb        │   gateway)       │   │
│                      └──────────────────┘   │
└─────────────────────────────────────────────┘
         │                      │
         ▼                      ▼
   [prometheus:9090]      [mqtt broker]
   [pushgateway:9091]     [grafana:3000]
```

## Требования

- Raspberry Pi 4B (aarch64) с Raspberry Pi OS / Debian
- Docker ≥ 20.10, Docker Compose ≥ v2
- CO2 датчик Holtek USB-zyTemp (04d9:a052)
- Удалённый MQTT брокер или Prometheus Pushgateway

## Быстрый старт

```bash
# 1. Клонировать репозиторий вместе с submodule
git clone --recurse-submodules https://github.com/YOUR_USER/dadjet_co2.git
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
git clone --recurse-submodules https://github.com/YOUR_USER/dadjet_co2.git ~/dadjet_co2
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

Обязательные параметры:

```env
# --- MQTT ---
MQTT_HOST=mqtt.example.com
MQTT_PORT=1883
MQTT_USER=your_username
MQTT_PASS=your_password
MQTT_TOPIC_PREFIX=home/sensors/co2monitor

# --- Prometheus Pushgateway (если используете) ---
PUSHGATEWAY_URL=https://pushgateway.example.com
JOB_NAME=co2monitor
INSTANCE_NAME=home

# LOCAL_METRICS_URL переопределяется в docker-compose.yml автоматически
```

### 4. udev rules для USB-датчика

Нужно сделать **один раз на хосте**, чтобы Docker-контейнер мог обращаться к USB HID:

```bash
sudo cp co2mon/udevrules/99-co2mon.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Правило разрешает доступ к устройству `04d9:a052` без root:
```
SUBSYSTEM=="usb", ATTR{idVendor}=="04d9", ATTR{idProduct}=="a052", MODE="0666"
```

После подключения датчика убедитесь, что он виден:
```bash
lsusb | grep 04d9
# Bus 001 Device 003: ID 04d9:a052 Holtek Semiconductor, Inc. USB-zyTemp
```

### 5. Сборка и запуск

```bash
# Собрать оба образа (co2mond + co2push)
docker compose build

# Запустить в фоне
docker compose up -d

# Проверить логи
docker compose logs -f
```

## Образы Docker

Оба образа построены на **Alpine Linux 3.21** — минимальный размер:

| Образ | Содержимое | Размер |
|-------|-----------|--------|
| `dadjet-co2mond` | `co2mond` + `hidapi` + `libusb` | ~12 MB |
| `dadjet-co2push` | `bash` + `curl` + `mosquitto_pub` | ~18 MB |

Сборка `co2mond` происходит из исходников внутри multi-stage Dockerfile.

## Выбор метода публикации

По умолчанию запускается **MQTT**-публикатор (`push_co2_mqtt.sh`).

Для переключения на **Prometheus Pushgateway** раскомментируйте в `docker-compose.yml`:
```yaml
co2push:
  # ...
  command: ["/app/push_co2_data.sh"]
```

Для одновременной публикации в MQTT **и** Pushgateway — добавьте второй сервис:
```yaml
  co2push-prometheus:
    build:
      context: .
      target: co2push
    container_name: co2push-prometheus
    restart: unless-stopped
    depends_on:
      - co2mond
    env_file: .env
    environment:
      LOCAL_METRICS_URL: http://co2mond:9999/metrics
    command: ["/app/push_co2_data.sh"]
    networks:
      - co2net
```

## Управление

```bash
# Статус контейнеров
docker compose ps

# Логи в реальном времени
docker compose logs -f

# Логи только co2mond
docker compose logs -f co2mond

# Перезапуск
docker compose restart

# Остановить
docker compose down

# Остановить и удалить образы
docker compose down --rmi local

# Пересобрать и перезапустить
docker compose up -d --build
```

## Проверка работы

```bash
# Метрики с датчика (внутри RPi)
curl http://localhost:9999/metrics

# Подписаться на MQTT-топики
mosquitto_sub -h mqtt.example.com -u user -P pass \
  -t "home/sensors/co2monitor/#" -v

# Проверить Pushgateway
curl https://pushgateway.example.com/metrics | grep co2
```

Ожидаемый вывод `/metrics`:
```
# HELP co2mon_co2_ppm CO2 concentration
# TYPE co2mon_co2_ppm gauge
co2mon_co2_ppm 520
# HELP co2mon_temp_celsius Ambient temperature
# TYPE co2mon_temp_celsius gauge
co2mon_temp_celsius 23.4375
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

### Датчик не найден в контейнере

```bash
# Убедитесь, что датчик виден на хосте
lsusb | grep 04d9

# Проверьте udev rules
ls -la /etc/udev/rules.d/99-co2mon.rules

# Проверьте логи co2mond
docker compose logs co2mond
```

### Нет данных в метриках

```bash
# Проверьте что co2mond запущен
docker compose ps

# Попробуйте вручную внутри контейнера
docker exec -it co2mond co2mond -P 0.0.0.0:9999
```

### Ошибка подключения к MQTT

```bash
# Проверьте .env
cat .env | grep MQTT

# Тест mosquitto_pub вручную внутри контейнера
docker exec -it co2push mosquitto_pub \
  -h "$MQTT_HOST" -p "$MQTT_PORT" \
  -u "$MQTT_USER" -P "$MQTT_PASS" \
  -t "test/co2" -m "hello"
```

### Проблема с USB-доступом (permission denied)

```bash
# Убедитесь, что co2mond запущен с privileged: true
docker inspect co2mond | grep -i privileged

# Переустановите udev rules
sudo cp co2mon/udevrules/99-co2mon.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
# Переподключите датчик
```

## Миграция с macOS

1. Остановить сервисы на Mac-сервере:
   ```bash
   # На Mac
   sudo launchctl stop com.co2mon
   sudo launchctl stop com.co2push
   ```
2. Перенести датчик в USB порт Raspberry Pi
3. Убедиться что датчик виден: `lsusb | grep 04d9`
4. Запустить контейнеры: `docker compose up -d`

## Файлы проекта

```
dadjet_co2/
├── Dockerfile               # Multi-stage Alpine: co2mond + co2push
├── docker-compose.yml       # Оркестрация сервисов
├── .env.example             # Шаблон конфигурации
├── push_co2_data.sh         # Публикатор → Prometheus Pushgateway
├── push_co2_mqtt.sh         # Публикатор → MQTT broker
├── co2mon/                  # Git submodule (github.com/dmage/co2mon)
│   ├── co2mond/             # Daemon: считывает USB HID, экспортирует метрики
│   ├── libco2mon/           # Библиотека: HID-протокол датчика
│   └── udevrules/           # Правила udev для USB-устройства
└── README.md                # Эта инструкция
```

## Безопасность

- Файл `.env` с секретами исключён из git через `.gitignore`
- Используйте HTTPS для Pushgateway
- Настройте аутентификацию для MQTT брокера
- `privileged: true` в Docker нужен только для USB HID — при возможности
  замените на точечный `devices` mount после настройки udev rules
