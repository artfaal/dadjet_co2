#!/bin/bash

# Load environment variables from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
else
    echo "ERROR: .env file not found. Copy .env.example to .env and configure it."
    exit 1
fi

# Set defaults if not specified in .env
MQTT_HOST="${MQTT_HOST:-mqtt.example.com}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-your_username}"
MQTT_PASS="${MQTT_PASS:-your_password}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-home/sensors/co2monitor}"
LOCAL_METRICS_URL="${LOCAL_METRICS_URL:-http://localhost:9999/metrics}"
PUSH_INTERVAL="${PUSH_INTERVAL:-30}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_mosquitto() {
    if ! command -v mosquitto_pub &> /dev/null; then
        log "ERROR: mosquitto_pub not found. Install with: brew install mosquitto"
        exit 1
    fi
}

check_local_metrics() {
    if ! curl -s --max-time 5 "$LOCAL_METRICS_URL" > /dev/null 2>&1; then
        log "ERROR: Local metrics not available at $LOCAL_METRICS_URL"
        return 1
    fi
    return 0
}

publish_mqtt() {
    local topic=$1
    local value=$2
    local retain=$3
    
    if [ -z "$MQTT_USER" ] || [ "$MQTT_USER" = "your_username" ]; then
        # Без аутентификации
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "$topic" -m "$value" $retain
    else
        # С аутентификацией
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$value" $retain
    fi
}

log "Starting CO2 MQTT publisher"
check_mosquitto

while true; do
    if ! check_local_metrics; then
        sleep 30
        continue
    fi

    # Получаем метрики
    METRICS=$(curl -s --max-time 5 "$LOCAL_METRICS_URL" | grep -E "^co2mon_(temp_celsius|co2_ppm)")
    
    if [ -z "$METRICS" ]; then
        log "WARNING: No metrics found"
        sleep "$PUSH_INTERVAL"
        continue
    fi

    # Извлекаем значения
    TEMP=$(echo "$METRICS" | grep temp_celsius | awk '{print $2}')
    CO2=$(echo "$METRICS" | grep co2_ppm | awk '{print $2}')

    if [ -z "$CO2" ] || [ -z "$TEMP" ]; then
        log "WARNING: Missing CO2 or Temperature data"
        sleep "$PUSH_INTERVAL"
        continue
    fi

    # Отправляем данные в MQTT
    if publish_mqtt "$MQTT_TOPIC_PREFIX/co2" "$CO2" "-r" && \
       publish_mqtt "$MQTT_TOPIC_PREFIX/temperature" "$TEMP" "-r"; then
        log "SUCCESS: Published CO2=$CO2 ppm, Temp=$TEMP°C"
    else
        log "ERROR: Failed to publish to MQTT"
    fi

    sleep "$PUSH_INTERVAL"
done
