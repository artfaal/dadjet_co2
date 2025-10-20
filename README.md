# CO2 Monitor для macOS с отправкой в Prometheus и MQTT

Мониторинг CO2 датчика (Holtek 04d9:a052) на macOS с автоматической отправкой данных в Prometheus Pushgateway или MQTT broker.

## Требования

- macOS с Homebrew
- CO2 датчик (Holtek USB-zyTemp)
- Удаленный сервер с Docker для Prometheus/Grafana

## Установка

### 1. Установите зависимости

```bash
brew install cmake pkg-config hidapi
```

### 2. Скомпилируйте co2mon

```bash
cd /path/to/co2mon

# Исправьте версию CMake во всех файлах
find . -name "CMakeLists.txt" -exec sed -i '' 's/cmake_minimum_required(VERSION 2.8)/cmake_minimum_required(VERSION 3.5)/g' {} \;

# Соберите проект
mkdir build
cd build
cmake ..
make
```

### 3. Проверьте работу

```bash
# Подключите датчик к USB
# Запустите для проверки:
sudo ./co2mond/co2mond

# Должны появиться строки вида:
# Tamb    24.2250
# CntR    470
```

### 4. Установите автозапуск через launchd

Создайте файл `/Library/LaunchDaemons/com.co2mon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.co2mon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/PROJECTS/co2mon/build/co2mond/co2mond</string>
        <string>-P</string>
        <string>127.0.0.1:9999</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/co2mon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/co2mon.err</string>
</dict>
</plist>
```

**Замените YOUR_USERNAME на ваше имя пользователя!**

Запустите сервис:

```bash
sudo launchctl load /Library/LaunchDaemons/com.co2mon.plist
sudo launchctl start com.co2mon

# Проверка работы
curl http://localhost:9999/metrics
```

### 5. Настройте переменные окружения

Создайте `.env` файл из примера и настройте под себя:

```bash
cp .env.example .env
nano .env
```

Укажите ваши настройки:
- `PUSHGATEWAY_URL` - адрес вашего Prometheus Pushgateway
- `MQTT_HOST`, `MQTT_USER`, `MQTT_PASS` - настройки MQTT брокера (если используете)
- Другие параметры по необходимости

### 6. Выберите и настройте скрипт отправки данных

Доступны два варианта:
- `push_co2_data.sh` - отправка в Prometheus Pushgateway
- `push_co2_mqtt.sh` - отправка в MQTT с округлением значений (CO2 до целого, температура до 1 знака)

Выберите нужный скрипт и установите автозапуск. Создайте файл `/Library/LaunchDaemons/com.co2push.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.co2push</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/PROJECTS/dadjet_co2/push_co2_data.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/co2push.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/co2push.err</string>
</dict>
</plist>
```

Запустите:

```bash
sudo launchctl load /Library/LaunchDaemons/com.co2push.plist
sudo launchctl start com.co2push
```

## Настройка сервера (Docker)

### Вариант 1: Prometheus + Pushgateway

На вашем сервере создайте `docker-compose.yml`:

```yaml
version: '3'

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

Создайте `prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'pushgateway'
    honor_labels: true
    static_configs:
      - targets: ['pushgateway:9091']
```

Запустите:

```bash
docker-compose up -d
```

### Вариант 2: MQTT Broker

```yaml
version: '3'

services:
  mosquitto:
    image: eclipse-mosquitto
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
      - "9001:9001"
    volumes:
      - ./mosquitto.conf:/mosquitto/config/mosquitto.conf
      - mosquitto-data:/mosquitto/data
      - mosquitto-logs:/mosquitto/log

volumes:
  mosquitto-data:
  mosquitto-logs:
```

## Настройка Grafana

1. Добавьте Data Source:
   - **Для Prometheus**: Type: Prometheus, URL: http://prometheus:9090
   - **Для MQTT**: установите плагин MQTT и укажите адрес брокера
2. Создайте дашборд с метриками:
   - `co2_ppm` - уровень CO2
   - `temperature` - температура

## Проверка работы

```bash
# На Mac проверьте логи
tail -f /tmp/co2mon.log
tail -f /tmp/co2push.log

# Проверьте метрики локально
curl http://localhost:9999/metrics

# Проверьте что данные доходят до Pushgateway
curl https://your-pushgateway-url/metrics | grep co2

# Для MQTT подпишитесь на топики
mosquitto_sub -h your-mqtt-host -t "home/sensors/co2monitor/#"
```

## Управление сервисами

```bash
# Остановить co2mon
sudo launchctl stop com.co2mon

# Запустить co2mon
sudo launchctl start com.co2mon

# Удалить из автозапуска
sudo launchctl unload /Library/LaunchDaemons/com.co2mon.plist

# Перезапустить после изменений
sudo launchctl unload /Library/LaunchDaemons/com.co2mon.plist
sudo launchctl load /Library/LaunchDaemons/com.co2mon.plist
```

## Устранение неполадок

### Устройство не открывается

1. Отключите и подключите датчик заново
2. Проверьте что устройство видно: `system_profiler SPUSBDataType | grep 04d9`
3. Перезапустите сервис

### Данные не отправляются на сервер

1. Проверьте логи: `tail -f /tmp/co2push.log`
2. Проверьте `.env` файл и его настройки
3. Проверьте доступность сервера
4. Убедитесь что скрипт запущен: `ps aux | grep push_co2`

### После перезагрузки не запускается

1. Проверьте что сервисы загружены:
   ```bash
   sudo launchctl list | grep co2
   ```
2. Проверьте права на файлы:
   ```bash
   ls -la /Library/LaunchDaemons/com.co2*.plist
   ```

## Безопасность

- Файл `.env` с приватными данными исключен из git через `.gitignore`
- Используйте HTTPS для Pushgateway
- Настройте аутентификацию для MQTT брокера
- Не коммитьте `.env` файл в репозиторий

## Файлы проекта

```
dadjet_co2/
├── README.md                      # Эта инструкция
├── .gitignore                    # Исключения для git
├── .env.example                  # Пример конфигурации
├── push_co2_data.sh              # Скрипт отправки в Prometheus Pushgateway
└── push_co2_mqtt.sh              # Скрипт отправки в MQTT broker
```

**Примечание**: Директория `co2mon/` исключена из репозитория (.gitignore), так как это отдельный git submodule.

## Первый запуск

1. Склонируйте репозиторий
2. Создайте `.env` из `.env.example` и настройте его
3. Следуйте инструкциям по установке выше
4. Не забудьте добавить `.env` в `.gitignore` (уже сделано)
