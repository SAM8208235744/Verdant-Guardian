const express = require("express");
const fetch = require("node-fetch");

let mqtt = null;
try {
  mqtt = require("mqtt");
} catch (_) {
  console.log("mqtt package not installed; bridge will run HTTP-only");
}

const app = express();
app.use(express.json({ limit: "64kb" }));

const devices = new Map();
const DEFAULT_TIMEOUT_MS = Number(process.env.DEVICE_TIMEOUT_MS || 1500);

function ensureDevice(id) {
  const key = id || "garden-node-1";
  if (!devices.has(key)) {
    devices.set(key, {
      id: key,
      ip: "",
      lastSeen: 0,
      lastStatus: null,
      schedules: [],
    });
  }
  return devices.get(key);
}

function commandPath(command) {
  const normalized = String(command || "").toUpperCase();
  if (normalized === "ON" || normalized === "START") return "on";
  if (normalized === "OFF" || normalized === "STOP") return "off";
  return normalized.toLowerCase();
}

async function fetchWithTimeout(url, options = {}, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function publishMqtt(topic, payload) {
  if (!mqttClient || !mqttClient.connected) return false;
  mqttClient.publish(topic, JSON.stringify(payload), { qos: 0 });
  return true;
}

async function forwardLocalControl(device, command, duration, commandId) {
  if (!device.ip) return { ok: false, status: 0, message: "No local IP" };

  const path = commandPath(command);
  const params = new URLSearchParams({
    duration: String(duration || 0),
    source: "watering_bridge",
  });
  if (commandId) params.set("commandId", commandId);

  const url = `http://${device.ip}/${path}?${params.toString()}`;
  try {
    const response = await fetchWithTimeout(url, { method: "GET" });
    return {
      ok: response.ok,
      status: response.status,
      message: response.ok ? "Local device accepted command" : "Local device returned an error",
    };
  } catch (error) {
    return { ok: false, status: 0, message: `Local device timeout/error: ${error.message}` };
  }
}

async function forwardLocalSchedule(device, schedule) {
  if (!device.ip) return { ok: false, status: 0, message: "No local IP" };

  try {
    const response = await fetchWithTimeout(`http://${device.ip}/schedule`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(schedule),
    });
    return { ok: response.ok, status: response.status };
  } catch (error) {
    return { ok: false, status: 0, message: error.message };
  }
}

const mqttUrl = process.env.MQTT_URL || "";
const mqttClient = mqtt && mqttUrl
  ? mqtt.connect(mqttUrl, {
      username: process.env.MQTT_USERNAME,
      password: process.env.MQTT_PASSWORD,
      rejectUnauthorized: process.env.MQTT_REJECT_UNAUTHORIZED !== "false",
    })
  : null;

if (mqttClient) {
  mqttClient.on("connect", () => {
    console.log("MQTT bridge connected");
    mqttClient.subscribe("water/+/status");
  });

  mqttClient.on("message", (topic, payload) => {
    const parts = topic.split("/");
    if (parts.length !== 3 || parts[0] !== "water" || parts[2] !== "status") return;

    try {
      const id = parts[1];
      const device = ensureDevice(id);
      device.lastStatus = JSON.parse(payload.toString());
      device.lastSeen = Date.now();
    } catch (error) {
      console.log("Ignored invalid MQTT status:", error.message);
    }
  });

  mqttClient.on("error", (error) => {
    console.log("MQTT bridge error:", error.message);
  });
}

app.post("/register", (req, res) => {
  const { id, ip } = req.body;
  if (!id || !ip) return res.status(400).json({ ok: false, message: "id and ip are required" });

  const device = ensureDevice(id);
  device.ip = ip;
  device.lastSeen = Date.now();
  console.log("Registered:", id, ip);
  res.json({ ok: true, device });
});

app.post("/control", async (req, res) => {
  const id = req.body.id || "garden-node-1";
  const command = req.body.command || req.body.cmd;
  const duration = Number(req.body.duration || 0);
  const commandId = req.body.commandId || `${Date.now()}_${command}`;

  if (!command) return res.status(400).json({ ok: false, message: "command is required" });

  const device = ensureDevice(id);
  const mqttOk = publishMqtt(`water/${id}/control`, {
    cmd: String(command).toUpperCase(),
    duration,
    commandId,
    source: req.body.source || "watering_bridge",
  });

  const local = await forwardLocalControl(device, command, duration, commandId);
  const ok = mqttOk || local.ok;

  res.status(ok ? 202 : 502).json({
    ok,
    commandId,
    local,
    mqtt: { ok: mqttOk, connected: Boolean(mqttClient && mqttClient.connected) },
  });
});

app.get("/devices/:id/status", async (req, res) => {
  const device = ensureDevice(req.params.id);

  if (device.ip) {
    try {
      const response = await fetchWithTimeout(`http://${device.ip}/status`, { method: "GET" });
      if (response.ok) {
        const status = await response.json();
        device.lastStatus = status;
        device.lastSeen = Date.now();
        return res.json(status);
      }
    } catch (_) {
      // MQTT cache below is still useful if local HTTP is unavailable.
    }
  }

  if (device.lastStatus) return res.json(device.lastStatus);
  res.status(404).json({ ok: false, message: "No status available yet" });
});

app.post("/devices/:id/schedule", async (req, res) => {
  const device = ensureDevice(req.params.id);
  const schedule = { ...req.body, source: req.body.source || "watering_bridge" };
  device.schedules[schedule.slot || 0] = schedule;

  const mqttOk = publishMqtt(`water/${device.id}/schedule`, schedule);
  const local = await forwardLocalSchedule(device, schedule);
  const ok = mqttOk || local.ok;

  res.status(ok ? 202 : 502).json({
    ok,
    local,
    mqtt: { ok: mqttOk, connected: Boolean(mqttClient && mqttClient.connected) },
  });
});

app.get("/devices", (req, res) => {
  res.json([...devices.values()]);
});

app.get("/", (req, res) => {
  res.json({
    ok: true,
    service: "watering bridge",
    mqttConnected: Boolean(mqttClient && mqttClient.connected),
    deviceCount: devices.size,
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Watering bridge started on port ${PORT}`));
