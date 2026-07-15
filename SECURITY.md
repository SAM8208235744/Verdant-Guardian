# Security policy

Verdant Guardian controls physical watering hardware. Treat every network command as potentially safety-relevant.

## Reporting a problem

Please report security issues privately to the repository owner instead of opening a public issue with credentials, home network details, or exploit steps.

## Deployment guidance

- Keep the ESP32 HTTP API and UDP discovery on a trusted home network.
- Use a private, authenticated MQTT broker with TLS.
- Put the optional bridge behind authentication and HTTPS before any internet exposure.
- Keep `firmware/verdant_controller/config.h` and `watering-server/.env` out of Git.
- Rotate leaked or reused Wi-Fi, MQTT, Telegram, weather, and OTA credentials immediately.
- Test manual shutoff, tank sensing, rain sensing, and maximum run-time behavior regularly.
