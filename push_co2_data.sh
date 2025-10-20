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
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-https://pushgateway.example.com}"
LOCAL_METRICS_URL="${LOCAL_METRICS_URL:-http://localhost:9999/metrics}"
JOB_NAME="${JOB_NAME:-co2monitor}"
INSTANCE_NAME="${INSTANCE_NAME:-home}"
PUSH_INTERVAL="${PUSH_INTERVAL:-10}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_local_metrics() {
    if ! curl -s --max-time 5 "$LOCAL_METRICS_URL" > /dev/null 2>&1; then
        log "ERROR: Local metrics not available"
        return 1
    fi
    return 0
}

log "Starting CO2 data push service"

while true; do
    if ! check_local_metrics; then
        sleep 30
        continue
    fi

    METRICS=$(curl -s --max-time 5 "$LOCAL_METRICS_URL" | grep -E "^co2mon_(temp_celsius|co2_ppm)")
    
    if [ -z "$METRICS" ]; then
        sleep "$PUSH_INTERVAL"
        continue
    fi

    TEMP=$(echo "$METRICS" | grep temp_celsius | awk '{print $2}')
    CO2=$(echo "$METRICS" | grep co2_ppm | awk '{print $2}')

    if [ -z "$CO2" ] || [ -z "$TEMP" ]; then
        sleep "$PUSH_INTERVAL"
        continue
    fi

    # Отправляем обе метрики вместе
    HTTP_CODE=$(cat <<EOF | curl -s -w "%{http_code}" -o /dev/null \
        -X POST --data-binary @- \
        "$PUSHGATEWAY_URL/metrics/job/$JOB_NAME/instance/$INSTANCE_NAME"
# TYPE co2_ppm gauge
co2_ppm $CO2
# TYPE temperature gauge
temperature $TEMP
EOF
)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
        log "SUCCESS: CO2=$CO2 ppm, Temp=$TEMP°C"
    else
        log "ERROR: HTTP $HTTP_CODE"
    fi

    sleep "$PUSH_INTERVAL"
done
