# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: build co2mond
#   Alpine + build tools → компилируем C-демон из исходников
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.21 AS builder

RUN apk add --no-cache \
    build-base \
    cmake \
    pkgconf \
    hidapi-dev \
    libusb-dev

WORKDIR /src
COPY co2mon/ .

# Проект использует устаревший cmake_minimum_required(VERSION 2.8) — исправляем
RUN find . -name "CMakeLists.txt" -exec sed -i \
    's/cmake_minimum_required(VERSION 2.8)/cmake_minimum_required(VERSION 3.5)/g' {} \;

RUN mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    make -j"$(nproc)"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: co2mond runtime
#   Только исполняемый файл + runtime-библиотеки hidapi/libusb
#   Итоговый размер образа ≈ 10–15 MB
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.21 AS co2mond

RUN apk add --no-cache hidapi libusb

COPY --from=builder /src/build/co2mond/co2mond /usr/local/bin/co2mond

EXPOSE 9999

CMD ["co2mond", "-P", "0.0.0.0:9999"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: co2push runtime
#   Alpine + bash + curl + mosquitto_pub
#   Итоговый размер образа ≈ 15–20 MB
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.21 AS co2push

RUN apk add --no-cache bash curl mosquitto-clients

WORKDIR /app
COPY push_co2_mqtt.sh push_co2_data.sh ./
RUN chmod +x push_co2_mqtt.sh push_co2_data.sh

# По умолчанию запускаем MQTT-publisher.
# Для Pushgateway: переопределите CMD в docker-compose.yml
CMD ["/app/push_co2_mqtt.sh"]
