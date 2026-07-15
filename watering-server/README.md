# Verdant Guardian bridge

This optional Node.js service connects a Flutter client, an MQTT broker, and controllers reachable over local HTTP. The ESP32 and Flutter app can communicate directly, so the bridge is not required for local use.

## Run locally

```bash
npm ci
npm start
```

The service listens on port `3000` by default. Environment variables are documented in `.env.example`.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/register` | Register a controller ID and local IP |
| `POST` | `/control` | Forward an on or off command by MQTT and local HTTP |
| `GET` | `/devices/:id/status` | Read live local status or the last MQTT status |
| `POST` | `/devices/:id/schedule` | Save and forward a schedule |
| `GET` | `/devices` | List known in-memory devices |
| `GET` | `/` | Return a bridge health summary |

Registrations and cached status are stored in memory and reset when the process restarts.

## Security boundary

The bridge does not include end-user authentication. Run it only on a trusted network or place it behind authenticated HTTPS infrastructure. Store broker credentials in environment variables and never commit a `.env` file.
