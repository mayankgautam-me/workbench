# weather-station

## Sensor firmware {#firmware}
tech: Zephyr, nRF52840
files: [firmware/**]
- [x] Read the BME280 over I2C {#fw-bme280}
- [x] Sleep between readings {#fw-sleep}
- [~] Verify a signed OTA image before booting it {#fw-ota-verify}
- [ ] Report battery voltage {#fw-battery}

## Gateway {#gateway}
tech: Go, MQTT bridge
files: [gateway/**]
needs: [firmware]
- [x] Bridge BLE readings to MQTT {#gw-bridge}
- [x] Push OTA images to a sensor {#gw-ota}
- [ ] Retry an upload after a dropped link {#gw-retry}

## Telemetry API {#api}
tech: Go, PostgreSQL
files: [api/**]
needs: [gateway]
- [x] Ingest one reading {#api-ingest}
- [~] Batch telemetry before writing it {#api-batch}
- [ ] Rate limits per device {#api-limits}
- [!] Retention policy: waits on the storage budget {#api-retention}

## Dashboard {#dashboard}
tech: SvelteKit
files: [dashboard/**]
needs: [api]
- [x] Live temperature and humidity {#dash-live}
- [x] Show wind gusts {#dash-gusts}
- [ ] Compare two stations {#dash-compare}

## Mobile app {#mobile}
tech: Flutter
files: [mobile/**]
needs: [api]
- [x] Pair a sensor over BLE {#app-pair}
- [ ] Alerts for frost {#app-frost}

## Infrastructure {#infra}
tech: Docker Compose, Make
files: [deploy/**, Makefile]
- [x] One command brings the stack up {#infra-up}
- [x] Nightly database backup {#infra-backup}
