#include <WiFi.h>
#include <WiFiUdp.h>
#include <PubSubClient.h>
#include <WebServer.h>
#include <Preferences.h>
#include <time.h>
#include <WiFiClientSecure.h>
#include <UniversalTelegramBot.h>
#include <ArduinoJson.h>
#include <esp_task_wdt.h>
#include <driver/ledc.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include <HTTPClient.h>
#include "config.h"

#define BOT_TOKEN VERDANT_TELEGRAM_BOT_TOKEN
#define CHAT_ID VERDANT_TELEGRAM_CHAT_ID

String deviceId = VERDANT_DEVICE_ID;
String serverUrl = VERDANT_SERVER_URL;

// These objects are initialized safely during setup
WiFiClientSecure espClient;
PubSubClient client(espClient);
UniversalTelegramBot *bot;

unsigned long lastTelegramCheck = 0;

// Pin assignments
#define RELAY_PIN   25
#define LED_PIN     2
#define LED_R       14
#define LED_G       27
#define LED_B       33
#define BTN_ON      5
#define BTN_OFF     26
#define FLOAT_PIN   32
#define RAIN_PIN    4

#define RELAY_ON  LOW
#define RELAY_OFF HIGH

#define MANUAL_DURATION_MIN 10
#define RAIN_DELAY_HOURS 6
#define WEATHER_API_KEY VERDANT_WEATHER_API_KEY
#define WEATHER_LAT VERDANT_WEATHER_LATITUDE
#define WEATHER_LON VERDANT_WEATHER_LONGITUDE
#define RAIN_PREDICT_HOURS 6

const char* ssid = VERDANT_WIFI_SSID;
const char* password = VERDANT_WIFI_PASSWORD;

const char* mqtt_server = VERDANT_MQTT_HOST;
const int mqtt_port = VERDANT_MQTT_PORT;
const char* mqtt_user = VERDANT_MQTT_USERNAME;
const char* mqtt_pass = VERDANT_MQTT_PASSWORD;

bool manualOverride = false;

unsigned long wateringEndTime = 0;
bool valveOn = false;
bool saveScheduleFromJson(JsonObject doc);

static unsigned long nextMqttAttemptAt = 0;
static uint8_t mqttFailCount = 0;

bool manualButtonPressedNow() {
  return digitalRead(BTN_ON) == LOW || digitalRead(BTN_OFF) == LOW;
}


void callback(char* topic, byte* payload, unsigned int length) {
  String topicStr = String(topic);
  String msg;

  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }

  Serial.println("MQTT Topic: " + topicStr);
  Serial.println("MQTT Msg: " + msg);

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, msg);

  if (err) {
    Serial.println("MQTT JSON parse failed");
    return;
  }

  String controlTopic = "water/" + deviceId + "/control";
  String scheduleTopic = "water/" + deviceId + "/schedule";

  if (topicStr == controlTopic) {
    String cmd = doc["cmd"] | "";
    int duration = doc["duration"] | 600;

    if (cmd == "ON") {
      valveOpen(max(1, duration / 60));
    } else if (cmd == "OFF") {
      valveClose();
    }

    return;
  }

  if (topicStr == scheduleTopic) {
    bool ok = saveScheduleFromJson(doc.as<JsonObject>());

    if (ok) {
      Serial.println("MQTT schedule saved");
      publishStatus(0);
    } else {
      Serial.println("MQTT schedule save failed");
    }

    return;
  }
}

void reconnectMQTT() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (client.connected()) return;
  if (strlen(mqtt_server) == 0) return;

  // Avoid MQTT connection attempts while a physical button is pressed
  if (manualButtonPressedNow()) {
    nextMqttAttemptAt = millis() + 10000UL;
    return;
  }

  unsigned long now = millis();

  if ((long)(now - nextMqttAttemptAt) < 0) {
    return;
  }

  Serial.print("Connecting MQTT...");

  bool ok = client.connect(deviceId.c_str(), mqtt_user, mqtt_pass);

  // Scan the buttons after the MQTT attempt returns
  handleManualButton();

  if (ok) {
    Serial.println("connected");

    mqttFailCount = 0;
    nextMqttAttemptAt = 0;

    String controlTopic = "water/" + deviceId + "/control";
    client.subscribe(controlTopic.c_str());

    String scheduleTopic = "water/" + deviceId + "/schedule";
    client.subscribe(scheduleTopic.c_str());

    String onlineTopic = "water/" + deviceId + "/online";
    client.publish(onlineTopic.c_str(), "ONLINE", true);

  } else {
    mqttFailCount++;

    Serial.print("failed, rc=");
    Serial.println(client.state());

    unsigned long retryDelay;

    if (mqttFailCount == 1) {
      retryDelay = 300000UL;       // 5 minutes
    } else if (mqttFailCount == 2) {
      retryDelay = 600000UL;       // 10 minutes
    } else {
      retryDelay = 900000UL;       // 15 minutes
    }

    // Use the current time after the blocking connection attempt
    nextMqttAttemptAt = millis() + retryDelay;

    Serial.print("Next MQTT retry in ");
    Serial.print(retryDelay / 1000);
    Serial.println(" sec");
  }
}

void publishStatus(int remaining) {
  if (!client.connected()) return;
  String payload = "{\"state\":\"" + String(valveOn ? "ON" : "OFF") +
                   "\",\"remaining\":" + String(remaining) + "}";
  String topic = "water/" + deviceId + "/status";

  client.publish(topic.c_str(), payload.c_str(), true);
}

WebServer server(80);
Preferences wifiPrefs;
Preferences waterPrefs;
String savedSSID;
String savedPASS;

struct Schedule {
  uint8_t hour;
  uint8_t minute;
  uint16_t duration;
  bool days[7];
  unsigned long lastRunDay;
  bool enabled;
};

#define SCHEDULE_COUNT 4
Schedule schedules[SCHEDULE_COUNT];

bool saveScheduleFromJson(JsonObject doc) {
  int slot = doc["slot"] | -1;

  if (slot < 0 || slot >= SCHEDULE_COUNT) {
    Serial.println("Invalid schedule slot");
    return false;
  }

  schedules[slot].hour = doc["hour"] | schedules[slot].hour;
  schedules[slot].minute = doc["minute"] | schedules[slot].minute;
  schedules[slot].duration = doc["duration"] | schedules[slot].duration;
  schedules[slot].enabled = doc["enabled"] | schedules[slot].enabled;

  JsonArray daysArray = doc["days"].as<JsonArray>();

  if (!daysArray.isNull() && daysArray.size() == 7) {
    for (int i = 0; i < 7; i++) {
      schedules[slot].days[i] = daysArray[i] | false;
      waterPrefs.putBool(("day" + String(slot) + String(i)).c_str(), schedules[slot].days[i]);
    }
  }

  waterPrefs.putUChar(("h" + String(slot)).c_str(), schedules[slot].hour);
  waterPrefs.putUChar(("m" + String(slot)).c_str(), schedules[slot].minute);
  waterPrefs.putUShort(("d" + String(slot)).c_str(), schedules[slot].duration);
  waterPrefs.putBool(("e" + String(slot)).c_str(), schedules[slot].enabled);

  Serial.println("Schedule saved:");
  Serial.println("Slot: " + String(slot));
  Serial.println("Time: " + String(schedules[slot].hour) + ":" + String(schedules[slot].minute));
  Serial.println("Duration: " + String(schedules[slot].duration));
  Serial.println("Enabled: " + String(schedules[slot].enabled));

  return true;
}

// System state
int errorCount = 0;
const int MAX_ERRORS = 5;
int bootCount = 0;
bool safeMode = false;

bool manualLock = false;
bool systemReady = false;
bool manualWatering = false;
bool tankHasWater = true;
bool isWaterAvailable();
bool rainPreviouslyDetected = false;
bool lastValveState = false;
bool rainForecastCache = false;
bool lastValveStateRT = false;
bool lastTankStateRT = true;
unsigned long lastRemainingRT = 0;
static unsigned long lastMqttHeartbeat = 0;
static unsigned long lastUdpHeartbeat = 0;
static String lastCommand = "";

unsigned long rainWetStart = 0;
unsigned long rainWetDuration = 0;
unsigned long lastWeatherCheck = 0;
bool rainWasWet = false;
unsigned long rainDelayUntil = 0;
unsigned long valveStartTime = 0;
const unsigned long MAX_WATER_TIME = 30UL * 60UL * 1000UL;
unsigned long wateringStart = 0;
unsigned long activeDuration = 0;
unsigned long valveStartEpoch = 0;
unsigned long lastRunEpoch = 0;
unsigned long lastScheduleRunEpoch[SCHEDULE_COUNT] = {0};
unsigned long lastBroadcast = 0;
unsigned long lastValveClose = 0;
unsigned long lastReboot = 0;
const unsigned long REBOOT_INTERVAL = 604800000;
unsigned long wifiLostTime = 0;
unsigned long lastValveCloseTime = 0;
bool tankWasFullAtClose = false;
static unsigned long lastMsg = 0;
unsigned long bootTime = 0;

const unsigned long debounceDelay = 50;
WiFiUDP udp;
const int DISCOVERY_PORT = 4210;


unsigned long calculateRainDelay(unsigned long wetSeconds) {
  if (wetSeconds < 120) return 0;
  if (wetSeconds < 600) return 2UL * 3600UL;
  if (wetSeconds < 1800) return 6UL * 3600UL;
  return 12UL * 3600UL;
}

enum LedMode { LED_IDLE, LED_WATERING, LED_WIFI_LOST, LED_TRIPLE_FLASH, LED_PULSE, LED_EMERGENCY, LED_UNLOCK_FLASH };
LedMode currentLedMode = LED_IDLE;

void setRGB(uint8_t r, uint8_t g, uint8_t b, int limit) {
  r = min(r, (uint8_t)limit);
  g = min(g, (uint8_t)limit);
  b = min(b, (uint8_t)limit);
  ledcWrite(0, r); ledcWrite(1, g); ledcWrite(2, b);
}

void saveValveState() {
  if (lastValveState != valveOn) {
    waterPrefs.putBool("valveOn", valveOn);
    lastValveState = valveOn;
  }
}

void WiFiEvent(WiFiEvent_t event) {
  switch(event) {
    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED: WiFi.reconnect(); break;
    case ARDUINO_EVENT_WIFI_STA_CONNECTED: Serial.println("WiFi Connected"); break;
    case ARDUINO_EVENT_WIFI_STA_GOT_IP:
      Serial.print("IP: "); Serial.println(WiFi.localIP());
      if (MDNS.begin("water-controller")) Serial.println("mDNS started");
      break;
    default: break;
  }
}

void updateWiFiCredentials(String newSSID, String newPASS) {
  savedSSID = newSSID;
  savedPASS = newPASS;
  wifiPrefs.putString("ssid", newSSID);
  wifiPrefs.putString("pass", newPASS);
  WiFi.disconnect(true);
  delay(500);
  WiFi.begin(newSSID.c_str(), newPASS.c_str());
}

void checkServerCommand() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (serverUrl.length() == 0) return;

  HTTPClient http;
  http.begin(serverUrl + "/get-command?id=" + deviceId);

  int httpCode = http.GET();

  String payload = "";

  if (httpCode == 200) {

   payload = http.getString();
   Serial.println("Cloud payload: " + payload);

  if (payload == "ON" || payload == "OFF") {
    lastCommand = payload;

    if (payload == "ON") {
      valveOpen(MANUAL_DURATION_MIN);
      lastCommand = "";
    }
    else if (payload == "OFF"){

      valveClose();
      lastCommand = "";
      }
   }
  }

  http.end();
   Serial.println("Checking cloud...");
   Serial.println("HTTP Code: " + String(httpCode));
   Serial.println("Payload: " + payload);
}

void sendToCloud(String state) {
  // MQTT status is handled by broadcastRealtimeSmart
  return;
}

void registerToCloud() {
  if (serverUrl.length() == 0) return;
  HTTPClient http;

  http.begin(serverUrl + "/register");
  http.addHeader("Content-Type", "application/json");

  String json = "{\"id\":\"" + deviceId + "\",\"ip\":\"" + WiFi.localIP().toString() + "\"}";

  http.POST(json);
  http.end();
}

bool isRainExpectedSoon() {
  if (WiFi.status() != WL_CONNECTED) return false;
  if (strlen(WEATHER_API_KEY) == 0) return false;
  WiFiClientSecure client;
  client.setInsecure();
  lastWeatherCheck = millis();
  String url = "/data/2.5/forecast?lat=" + String(WEATHER_LAT) + "&lon=" + String(WEATHER_LON) + "&appid=" + String(WEATHER_API_KEY);
  if (!client.connect("api.openweathermap.org", 443)) return false;
  client.print(String("GET ") + url + " HTTP/1.1\r\n" + "Host: api.openweathermap.org\r\n" + "Connection: close\r\n\r\n");
  while (client.connected()) {
    String line = client.readStringUntil('\n');
    if (line == "\r") break;
  }
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, client);
  if (err) return rainForecastCache;
  JsonArray list = doc["list"];
  for (int i = 0; i < (RAIN_PREDICT_HOURS / 3) && i < list.size(); i++) {
    if ((list[i]["pop"] | 0) > 0.5) { rainForecastCache = true; return true; }
  }
  rainForecastCache = false;
  return false;
}

bool isRaining() {
  static uint32_t lastCheck = 0;
  static bool raining = false;
  if (millis() - lastCheck > 300) {
    lastCheck = millis();
    raining = (digitalRead(RAIN_PIN) == LOW);
  }
  return raining;
}

bool isRainDelayActive() {
  if (rainDelayUntil == 0) return false;
  return nowEpoch() < rainDelayUntil;
}

bool cloudNotSafeForBlockingCalls() {
  if (WiFi.status() != WL_CONNECTED) return true;

  // Treat the cloud as unavailable after an MQTT failure
  // Keep Telegram and HTTPS from blocking manual buttons
  if (!client.connected() && mqttFailCount > 0) return true;

  return false;
}

void sendTelegram(String msg) {
  if (!systemReady || bot == nullptr) return;
  if (cloudNotSafeForBlockingCalls()) return;

  bot->sendMessage(CHAT_ID, msg, "");
}

void valveOpen(uint16_t durationMin) {
  if (safeMode) return;
  if (manualLock) {
    Serial.println("Blocked: Manual Lock");
    return;
  }
  if (rainForecastCache || isRaining() || isRainDelayActive()) return;
  if (!isWaterAvailable()) return;
  if (millis() - lastValveClose < 10000 || valveOn) return;

  unsigned long now = nowEpoch();
  if (systemReady && (millis() - lastMsg > 10000)) {
    sendTelegram("Watering started\nDuration: " + String(durationMin) + " min");
    lastMsg = millis();
  }

  digitalWrite(RELAY_PIN, RELAY_ON);
  currentLedMode = LED_WATERING;
  digitalWrite(LED_PIN, HIGH);
  manualWatering = manualOverride;
  wateringStart = millis();
  valveOn = true;
  valveStartTime = millis();
  valveStartEpoch = now;
  activeDuration = durationMin * 60UL;
  errorCount = 0;
  sendToCloud("ON");

  waterPrefs.putBool("valveOn", true);
  waterPrefs.putULong("startEpoch", valveStartEpoch);
  waterPrefs.putULong("durationSec", activeDuration);
  saveValveState();

  Serial.println("DEBUG: valveOpen called");

   if (rainForecastCache) Serial.println("Blocked: Rain forecast");
   if (isRaining()) Serial.println("Blocked: Raining");
   if (isRainDelayActive()) Serial.println("Blocked: Rain delay");
   if (!isWaterAvailable()) Serial.println("Blocked: No water");
   if (manualLock) Serial.println("Blocked: Manual Lock");

   String topic = "water/" + deviceId + "/status";
   unsigned long remaining = activeDuration;

    String status = "{\"state\":\"ON\",\"remaining\":" + String(remaining) + "}";

   if (client.connected()) {
  client.publish(topic.c_str(), status.c_str(), true);
  }
}

void valveClose() {
  if (systemReady && (millis() - lastMsg > 10000)) {
    sendTelegram("Watering stopped");
    lastMsg = millis();
  }
  digitalWrite(RELAY_PIN, RELAY_OFF);
  currentLedMode = LED_IDLE;
  digitalWrite(LED_PIN, LOW);
  lastValveClose = millis();
  manualWatering = false;
  valveOn = false;
  activeDuration = 0;
  lastValveCloseTime = millis();
  tankWasFullAtClose = isWaterAvailable();
  waterPrefs.putBool("valveOn", false);
  sendToCloud("OFF");
  String topic = "water/" + deviceId + "/status";
  if (client.connected()) {
  client.publish(topic.c_str(), "{\"state\":\"OFF\"}", true);
  }
}

unsigned long nowEpoch() {
  time_t t;
  time(&t);
  return t;
}

void handleRoot() {
  String page = R"rawliteral(<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{font-family:Arial;background:#0f172a;color:white;margin:0;padding:20px;}.card{background:#1e293b;padding:15px;border-radius:15px;margin-bottom:15px;}.status-on{color:#22c55e;font-weight:bold;}.status-off{color:#ef4444;font-weight:bold;}button{width:100%;padding:15px;font-size:18px;border:none;border-radius:12px;margin-top:10px;cursor:pointer;}.on-btn{background:#22c55e;color:white;}.off-btn{background:#ef4444;color:white;}input[type=number]{width:100%;padding:8px;margin:5px 0;border-radius:8px;border:none;}.toggle{transform:scale(1.5);}.save-btn{background:#3b82f6;color:white;}</style></head><body><h2>Smart Irrigation</h2>)rawliteral";
  page += valveOn ? "<p>Status: <span class='status-on'>ON</span></p>" : "<p>Status: <span class='status-off'>OFF</span></p>";
  page += R"rawliteral(<div class="card"><a href="/on"><button class="on-btn">TURN ON</button></a><a href="/off"><button class="off-btn">TURN OFF</button></a></div><form action="/save">)rawliteral";
  for (int i = 0; i < SCHEDULE_COUNT; i++) {
    page += "<div class='card'><h3>Schedule " + String(i + 1) + "</h3>";
    page += "Hour:<input type='number' name='h" + String(i) + "' value='" + String(schedules[i].hour) + "' min='0' max='23'>";
    page += "Minute:<input type='number' name='m" + String(i) + "' value='" + String(schedules[i].minute) + "' min='0' max='59'>";
    page += "Duration (min):<input type='number' name='d" + String(i) + "' value='" + String(schedules[i].duration) + "'>";
    page += "<p>Days:</p>";
    const char* dayNames[7] = {"S","M","T","W","T","F","Sa"};
    for (int d = 0; d < 7; d++) {
      page += "<label style='margin-right:8px;'>" + String(dayNames[d]) + "<input type='checkbox' name='day" + String(i) + String(d) + "'" + (schedules[i].days[d] ? " checked" : "") + "></label>";
    }
    page += "Enable: <input type='checkbox' class='toggle' name='e" + String(i) + "'" + (schedules[i].enabled ? " checked" : "") + "></div>";
  }
  page += R"rawliteral(<button type="submit" class="save-btn">Save Settings</button></form></body></html>)rawliteral";
  server.send(200, "text/html", page);
}

void handleTelegram() {
  if (millis() - lastTelegramCheck < 3000) return;
  lastTelegramCheck = millis();
  if (bot == nullptr) return;
  int msgCount = bot->getUpdates(bot->last_message_received + 1);
  while (msgCount) {
    for (int i = 0; i < msgCount; i++) {
      if (bot->messages[i].chat_id != CHAT_ID) continue;
      String text = bot->messages[i].text;
      if (text == "/on") { valveOpen(MANUAL_DURATION_MIN); currentLedMode = LED_PULSE; }
      if (text == "/off") valveClose();
      if (text == "/status") {
        String s = valveOn ? "ON" : "OFF";
        if (millis() - lastMsg > 10000) { sendTelegram("Status: " + s); lastMsg = millis(); }
      }
    }
    msgCount = bot->getUpdates(bot->last_message_received + 1);
  }
}

void handleDiscovery() {
  int packetSize = udp.parsePacket();
  if (!packetSize) return;

  char incoming[256];
  int len = udp.read(incoming, sizeof(incoming) - 1);
  if (len <= 0) return;

  incoming[len] = 0;
  String msg = String(incoming);
  msg.trim();

  Serial.println("UDP RX: " + msg);

  // Discovery request
  if (msg == "WATER_DISCOVERY_REQUEST") {
    JsonDocument doc;
    doc["name"] = "Garden Controller";
    doc["device"] = "water";
    doc["id"] = deviceId;
    doc["ip"] = WiFi.localIP().toString();

    char buffer[256];
    serializeJson(doc, buffer);

    udp.beginPacket(udp.remoteIP(), udp.remotePort());
    udp.write((uint8_t*)buffer, strlen(buffer));
    udp.endPacket();

    return;
  }

  // Command handler
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, msg);

  if (err) {
    Serial.println("Invalid UDP JSON");
    return;
  }

  String cmd = doc["cmd"];
  int duration = doc["duration"] | 600;

  Serial.println("UDP command: " + cmd);

  if (cmd == "ON") {
    valveOpen(max(1, duration / 60));
  }
  else if (cmd == "OFF") {
    valveClose();
  }
}

void handleSave() {
  for (int i = 0; i < SCHEDULE_COUNT; i++) {
    schedules[i].hour = server.arg("h" + String(i)).toInt();
    schedules[i].minute = server.arg("m" + String(i)).toInt();
    schedules[i].duration = server.arg("d" + String(i)).toInt();
    schedules[i].enabled = server.hasArg("e" + String(i));
    waterPrefs.putUChar(("h" + String(i)).c_str(), schedules[i].hour);
    waterPrefs.putUChar(("m" + String(i)).c_str(), schedules[i].minute);
    waterPrefs.putUShort(("d" + String(i)).c_str(), schedules[i].duration);
    waterPrefs.putBool(("e" + String(i)).c_str(), schedules[i].enabled);
    for (int d = 0; d < 7; d++) {
      bool dayEnabled = server.hasArg("day" + String(i) + String(d));
      schedules[i].days[d] = dayEnabled;
      waterPrefs.putBool(("day" + String(i) + String(d)).c_str(), dayEnabled);
    }
  }
  server.sendHeader("Location", "/");
  server.send(303);
}

void handleOn() {
  server.send(200, "text/plain", "Manual ON");
  valveOpen(10);
}

void handleOff() {
  server.send(200, "text/plain", "Manual OFF");
  valveClose();
}

void handleManualButton() {
  static unsigned long onPressStart = 0;
  static bool onPressedHandled = false;

  static unsigned long offPressStart = 0;
  static bool offPressedHandled = false;

  int onReading = digitalRead(BTN_ON);
  int offReading = digitalRead(BTN_OFF);

  // Debug output
  static unsigned long lastDebugPrint = 0;
  if (millis() - lastDebugPrint > 1000) {
    Serial.print("DEBUG: ON Pin: "); Serial.print(onReading);
    Serial.print(" | OFF Pin: "); Serial.print(offReading);
    Serial.print(" | Lock: "); Serial.println(manualLock ? "LOCKED" : "UNLOCKED");
    lastDebugPrint = millis();
  }

  // On button

  if (onReading == LOW && !onPressedHandled) {
    onPressedHandled = true;
    onPressStart = millis();
    Serial.println("Button Event: ON Pressed");

    // Short press action
    if (!manualLock) {
      if (!valveOn) {
        valveOpen(MANUAL_DURATION_MIN);
        manualOverride = true;
        Serial.println("Action: Manual ON triggered");
      } else {
        Serial.println("Action: Ignored (Valve already ON)");
      }
    } else {
      Serial.println("Action: Ignored (SYSTEM IS LOCKED)");
    }
  }

  if (onReading == HIGH && onPressedHandled) {
    unsigned long pressDuration = millis() - onPressStart;
    onPressedHandled = false;

    if (pressDuration >= 3000) {
      // Unlock the manual controls
      manualLock = false;
      waterPrefs.putBool("lock", false);

      Serial.println("System UNLOCKED");
      sendTelegram("System Unlocked");

      currentLedMode = LED_UNLOCK_FLASH;  // Green blink
    }
  }

  // Off button

  if (offReading == LOW && !offPressedHandled) {
    offPressedHandled = true;
    offPressStart = millis();
    Serial.println("Button Event: OFF Pressed");
  }

  if (offReading == HIGH && offPressedHandled) {
    unsigned long pressDuration = millis() - offPressStart;
    offPressedHandled = false;

    if (pressDuration >= 3000) {
      // Emergency stop
      Serial.println("EMERGENCY STOP TRIGGERED");

      valveClose();
      manualOverride = false;
      manualLock = true;
      waterPrefs.putBool("lock", true);

      sendTelegram("EMERGENCY STOP ACTIVATED");

      currentLedMode = LED_EMERGENCY; // Red blink
    } else {
      // Normal stop
      Serial.println("Normal OFF triggered");

      if (valveOn) {
        valveClose();
      } else {
        Serial.println("Ignored: Valve already OFF");
      }
    }
  }
}

void handleInfo() {
  JsonDocument doc;
  doc["name"] = "Garden Controller";
  doc["deviceId"] = deviceId;
  doc["ip"] = WiFi.localIP().toString();
  doc["uptime"] = millis() / 1000;
  doc["valve"] = valveOn;
  String res; serializeJson(doc, res);
  server.send(200, "application/json", res);
}

void handleRainLogic() {
  bool rainingNow = isRaining();
  unsigned long now = nowEpoch();
  if (rainingNow && !rainWasWet) rainWetStart = now;
  if (!rainingNow && rainWasWet) {
    rainWetDuration = now - rainWetStart;
    unsigned long delaySec = calculateRainDelay(rainWetDuration);
    if (delaySec > 0) {
      rainDelayUntil = now + delaySec;
      if (millis() - lastMsg > 10000) {
         sendTelegram("Rain detected\nWet time: " + String(rainWetDuration) + " sec\nDelay applied");
         lastMsg = millis();
      }
    }
  }
  if (rainingNow && valveOn) {
    if (millis() - lastMsg > 10000) { sendTelegram("Rain started - watering stopped"); lastMsg = millis(); }
    valveClose();
  }
  rainWasWet = rainingNow;
}

void printResetReason() {
  esp_reset_reason_t reason = esp_reset_reason();
  Serial.print("Reset reason: ");
  switch (reason) {
    case ESP_RST_POWERON: Serial.println("Power On"); break;
    case ESP_RST_SW: Serial.println("Software Reset"); break;
    case ESP_RST_PANIC: Serial.println("Exception / Panic"); break;
    case ESP_RST_TASK_WDT: Serial.println("Task Watchdog"); break;
    case ESP_RST_WDT: Serial.println("Other Watchdog"); break;
    case ESP_RST_DEEPSLEEP: Serial.println("Deep Sleep Wake"); break;
    case ESP_RST_BROWNOUT: Serial.println("Brownout"); break;
    default: Serial.println("Unknown");
  }
}

void broadcastPresence() {
  if (WiFi.status() != WL_CONNECTED) return;
  JsonDocument doc;
  doc["device"] = "water";
  doc["id"]     = deviceId;   // Flutter reads the id field
  doc["ip"]     = WiFi.localIP().toString();
  char buffer[256];
  serializeJson(doc, buffer);
  udp.beginPacket(IPAddress(255, 255, 255, 255), DISCOVERY_PORT);
  udp.write((uint8_t*)buffer, strlen(buffer));
  udp.endPacket();
}

void broadcastRealtimeSmart() {
  static String lastState = "";


  unsigned long remaining = 0;

  if (valveOn) {
    unsigned long elapsed = nowEpoch() - valveStartEpoch;
    remaining = (elapsed >= activeDuration) ? 0 : activeDuration - elapsed;
  }

  String topic = "water/" + deviceId + "/status";

  // MQTT status
  JsonDocument mqttDoc;
  mqttDoc["state"] = valveOn ? "ON" : "OFF";
  mqttDoc["remaining"] = remaining;
  mqttDoc["duration"] = activeDuration;

  char mqttBuffer[128];
  serializeJson(mqttDoc, mqttBuffer);

  String currentState = mqttBuffer;

  bool mqttStateChanged = (currentState != lastState);
  bool mqttHeartbeat = millis() - lastMqttHeartbeat > 3000;

  if (client.connected() && (mqttStateChanged || mqttHeartbeat)) {
  client.publish(topic.c_str(), mqttBuffer, true);
  lastState = currentState;
  lastMqttHeartbeat = millis();
  }

  // UDP status
  bool tank = isWaterAvailable();

  bool udpStateChanged =
      (valveOn != lastValveStateRT) ||
      (tank != lastTankStateRT) ||
      (abs((long)remaining - (long)lastRemainingRT) > 5);

  bool udpHeartbeat = millis() - lastUdpHeartbeat > 10000;
  if (!udpStateChanged && !udpHeartbeat) return;

  JsonDocument doc;
  doc["device"] = "water";
  doc["id"] = deviceId;
  doc["ip"] = WiFi.localIP().toString();
  doc["state"] = valveOn ? "ON" : "OFF";
  doc["remaining"] = remaining;
  doc["tank"] = tank;

  char buffer[256];
  serializeJson(doc, buffer);

  udp.beginPacket(IPAddress(255,255,255,255), DISCOVERY_PORT);
  udp.write((uint8_t*)buffer, strlen(buffer));
  udp.endPacket();

  lastValveStateRT = valveOn;
  lastTankStateRT = tank;
  lastRemainingRT = remaining;
}

float breathePhase = 0.0f;

uint8_t smoothBreath(int maxBrightness) {
  breathePhase += 0.035f;
  if (breathePhase > TWO_PI) breathePhase = 0;
  float wave = (sin(breathePhase) + 1.0f) * 0.5f;
  wave = pow(wave, 2.2f);
  return (uint8_t)(wave * maxBrightness);
}

bool getCachedLocalTime(struct tm* timeinfo) {
  time_t now;
  time(&now);

  // Return immediately until time is synchronized
  if (now < 100000) {
    return false;
  }

  localtime_r(&now, timeinfo);
  return true;
}

void handleLED() {
  static unsigned long timer = 0;
  static bool blinkState = false;
  static int flashCount = 0;
  struct tm timeinfo;
  int hourNow = 12;

  if (getCachedLocalTime(&timeinfo)) {
  hourNow = timeinfo.tm_hour;
  }
  bool nightMode = (hourNow >= 22 || hourNow <= 6);
  int brightnessLimit = nightMode ? 80 : 255;
  if (WiFi.status() != WL_CONNECTED && !valveOn) currentLedMode = LED_WIFI_LOST;
  switch (currentLedMode) {
    case LED_WATERING: setRGB(0, 255, 0, brightnessLimit); break;
    case LED_EMERGENCY:
  if (millis() - timer > 300) {
    timer = millis();
    blinkState = !blinkState;
    setRGB(blinkState ? 255 : 0, 0, 0, brightnessLimit); // Red blink
  }
  break;

case LED_UNLOCK_FLASH:
  if (millis() - timer > 200) {
    timer = millis();
    blinkState = !blinkState;
    setRGB(0, blinkState ? 255 : 0, 0, brightnessLimit); // Green blink
    flashCount++;
    if (flashCount >= 6) {  // Blink a few times and return
      flashCount = 0;
      currentLedMode = LED_IDLE;
    }
  }
  break;

    case LED_IDLE: setRGB(0, 0, smoothBreath(brightnessLimit), brightnessLimit); break;
    case LED_WIFI_LOST:
      if (millis() - timer > 700) { timer = millis(); blinkState = !blinkState; setRGB(blinkState ? 255 : 0, 0, 0, brightnessLimit); }
      break;
    case LED_TRIPLE_FLASH:
      if (millis() - timer > 150) {
        timer = millis(); blinkState = !blinkState;
        setRGB(blinkState ? 180 : 0, 0, blinkState ? 180 : 0, brightnessLimit);
        flashCount++; if (flashCount >= 6) { flashCount = 0; currentLedMode = LED_WATERING; }
      }
      break;
    case LED_PULSE:
      if (millis() - timer > 120) {
        timer = millis(); blinkState = !blinkState;
        setRGB(0, blinkState ? 200 : 0, blinkState ? 200 : 0, brightnessLimit);
        flashCount++; if (flashCount >= 4) { flashCount = 0; currentLedMode = valveOn ? LED_WATERING : LED_IDLE; }
      }
      break;
  }
}

bool isWaterAvailable() {
  static uint32_t lastCheck = 0;
  static bool stableState = true;
  static int confidenceCounter = 0;
  const int REQUIRED_CONFIDENCE = 5;
  if (millis() - lastCheck > 500) {
    lastCheck = millis();
    bool currentReading = (digitalRead(FLOAT_PIN) == LOW);
    if (currentReading == stableState) { confidenceCounter = 0; }
    else {
      confidenceCounter++;
      if (confidenceCounter >= REQUIRED_CONFIDENCE) { stableState = currentReading; confidenceCounter = 0; }
    }
  }
  return stableState;
}

void ensureWiFi() {
  static unsigned long lastAttempt = 0;

  if (WiFi.status() == WL_CONNECTED) return;

  if (millis() - lastAttempt < 15000) return;
  lastAttempt = millis();

  Serial.println("WiFi reconnect attempt...");

  WiFi.disconnect(false);

  if (savedSSID != "") {
    WiFi.begin(savedSSID.c_str(), savedPASS.c_str());
  } else {
    WiFi.begin(ssid, password);
  }
}

void handleStatus() {
  unsigned long remaining = 0;
  if (valveOn) {
    unsigned long elapsed = nowEpoch() - valveStartEpoch;
    remaining = (elapsed >= activeDuration) ? 0 : activeDuration - elapsed;
  }
  JsonDocument doc;
  doc["state"] = valveOn ? "ON" : "OFF";
  doc["remaining"] = remaining;
  doc["duration"] = activeDuration;
  doc["rain"] = isRaining();
  doc["rainDelayActive"] = isRainDelayActive();
  doc["rainDelayRemaining"] = isRainDelayActive() ? (rainDelayUntil - nowEpoch()) : 0;
  doc["rainLastWetSec"] = rainWetDuration;
  doc["tank"] = isWaterAvailable();
  doc["wifi"] = WiFi.status() == WL_CONNECTED;
  doc["ip"] = WiFi.localIP().toString();
  doc["signal"] = WiFi.RSSI();
  doc["heap"] = ESP.getFreeHeap();
  doc["uptime"] = millis() / 1000;
  doc["device"] = deviceId;
  doc["safeMode"] = safeMode;
  String response; serializeJson(doc, response);
  server.send(200, "application/json", response);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  printResetReason();

  // Set relay state before configuring pins to prevent startup movement
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, RELAY_OFF);

  WiFi.onEvent(WiFiEvent);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(false);
  wifiPrefs.begin("wifi", false);
  savedSSID = wifiPrefs.getString("ssid", "");
  savedPASS = wifiPrefs.getString("pass", "");

  if (savedSSID == "") WiFi.begin(ssid, password);
  else WiFi.begin(savedSSID.c_str(), savedPASS.c_str());

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  pinMode(RAIN_PIN, INPUT_PULLUP);
  valveOn = false;
  pinMode(BTN_ON, INPUT_PULLUP);
  pinMode(BTN_OFF, INPUT_PULLUP);
  pinMode(FLOAT_PIN, INPUT_PULLUP);

  esp_task_wdt_init(60, true);
  esp_task_wdt_add(NULL);

  ledcSetup(0, 5000, 8); ledcSetup(1, 5000, 8); ledcSetup(2, 5000, 8);
  ledcAttachPin(LED_R, 0); ledcAttachPin(LED_G, 1); ledcAttachPin(LED_B, 2);

  waterPrefs.begin("water", false);
  manualLock = waterPrefs.getBool("lock", false);
  bootCount = waterPrefs.getInt("bootCount", 0);
  bootCount++;
  waterPrefs.putInt("bootCount", bootCount);
  if (bootCount > 5) safeMode = true;

  for (int i = 0; i < SCHEDULE_COUNT; i++) {
    schedules[i].hour = waterPrefs.getUChar(("h" + String(i)).c_str(), 6);
    schedules[i].minute = waterPrefs.getUChar(("m" + String(i)).c_str(), 0);
    schedules[i].duration = waterPrefs.getUShort(("d" + String(i)).c_str(), 20);
    schedules[i].enabled = waterPrefs.getBool(("e" + String(i)).c_str(), false);
    for (int d = 0; d < 7; d++) {
      schedules[i].days[d] = waterPrefs.getBool(("day" + String(i) + String(d)).c_str(), false);
    }
  }

  unsigned long wifiStart = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - wifiStart < 15000) delay(500);

  if (WiFi.status() == WL_CONNECTED) {
    if (MDNS.begin("water-controller")) Serial.println("mDNS started");
    Serial.println("mDNS started");
    MDNS.addService("http", "tcp", 80);
    MDNS.addService("arduino", "tcp", 3232);
  }

  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
  client.setSocketTimeout(1);   // MQTT connection and read timeout in seconds
  client.setKeepAlive(30);
  espClient.setTimeout(1000);   // Secure client timeout in milliseconds
  udp.begin(DISCOVERY_PORT);
  espClient.setInsecure();
  configTime(19800, 0, "pool.ntp.org");

  if (strlen(BOT_TOKEN) > 0 && strlen(CHAT_ID) > 0) {
    bot = new UniversalTelegramBot(BOT_TOKEN, espClient);
  }

  // Nonblocking time synchronization
  unsigned long timeStart = millis();
  while (time(nullptr) < 100000 && (millis() - timeStart < 3000)) {
  delay(200);
  Serial.print(".");
  }

  ArduinoOTA.setHostname("water-controller");
  if (strlen(VERDANT_OTA_PASSWORD) > 0) {
    ArduinoOTA.setPassword(VERDANT_OTA_PASSWORD);
  }

  // OTA debug callbacks
   ArduinoOTA.onStart([]() {
   digitalWrite(RELAY_PIN, RELAY_OFF); // Prevent watering during an update
   Serial.println("OTA Start");
});

   ArduinoOTA.onEnd([]() {
     Serial.println("\nOTA End");
  });

    ArduinoOTA.onProgress([](unsigned int progress, unsigned int total) {
     Serial.printf("Progress: %u%%\r", (progress * 100) / total);
  });

    ArduinoOTA.onError([](ota_error_t error) {
     Serial.printf("Error[%u]: ", error);
  });

  ArduinoOTA.begin();



  bool wasOn = waterPrefs.getBool("valveOn", false);
  if (wasOn) {
    unsigned long savedStart = waterPrefs.getULong("startEpoch", 0);
    unsigned long savedDuration = waterPrefs.getULong("durationSec", 0);
    unsigned long now = nowEpoch();
    if (now - savedStart < savedDuration) {
      unsigned long remaining = savedDuration - (now - savedStart);
      digitalWrite(RELAY_PIN, RELAY_ON);
      valveOn = true;
      valveStartEpoch = now;
      activeDuration = remaining;
      if (millis() - lastMsg > 10000) {
        sendTelegram("Power restored. Resuming watering.");
        lastMsg = millis();
      }
    } else {
      waterPrefs.putBool("valveOn", false);
    }
  }

  unsigned long currentTime = nowEpoch();
  for (int i = 0; i < SCHEDULE_COUNT; i++) lastScheduleRunEpoch[i] = currentTime;

  server.on("/", handleRoot);
  server.on("/save", handleSave);
  server.on("/on", handleOn);
  server.on("/off", handleOff);
  server.on("/status", handleStatus);
  server.on("/info", handleInfo);
  server.on("/setwifi", HTTP_POST, []() {
    JsonDocument doc;
    deserializeJson(doc, server.arg("plain"));
    updateWiFiCredentials(doc["ssid"], doc["pass"]);
    server.send(200, "application/json", "{\"status\":\"wifi_updated\"}");
  });
  server.on("/schedule", HTTP_POST, []() {
    if (!server.hasArg("plain")) { server.send(400, "text/plain", "No body"); return; }
    JsonDocument doc;
    if (deserializeJson(doc, server.arg("plain"))) { server.send(400, "text/plain", "JSON err"); return; }
    int slot = doc["slot"];
    if (slot < 0 || slot >= SCHEDULE_COUNT) { server.send(400, "text/plain", "Slot err"); return; }
    schedules[slot].hour = doc["hour"];
    schedules[slot].minute = doc["minute"];
    schedules[slot].duration = doc["duration"];
    schedules[slot].enabled = doc["enabled"];
    JsonArray daysArray = doc["days"];
    if (!daysArray.isNull() && daysArray.size() == 7) {
      for (int i = 0; i < 7; i++) {
        schedules[slot].days[i] = daysArray[i];
        waterPrefs.putBool(("day" + String(slot) + String(i)).c_str(), daysArray[i]);
      }
    }
    waterPrefs.putUChar(("h" + String(slot)).c_str(), schedules[slot].hour);
    waterPrefs.putUChar(("m" + String(slot)).c_str(), schedules[slot].minute);
    waterPrefs.putUShort(("d" + String(slot)).c_str(), schedules[slot].duration);
    waterPrefs.putBool(("e" + String(slot)).c_str(), schedules[slot].enabled);
    server.send(200, "text/plain", "Schedule Saved");
  });
  server.on("/getschedules", HTTP_GET, []() {
    JsonDocument doc;
    JsonArray arr = doc.to<JsonArray>();
    for (int i = 0; i < SCHEDULE_COUNT; i++) {
      JsonObject obj = arr.add<JsonObject>();
      obj["hour"] = schedules[i].hour;
      obj["minute"] = schedules[i].minute;
      obj["duration"] = schedules[i].duration;
      obj["enabled"] = schedules[i].enabled;
      JsonArray daysArray = obj["days"].to<JsonArray>();
      for (int d = 0; d < 7; d++) daysArray.add(schedules[i].days[d]);
    }
    String res; serializeJson(doc, res);
    server.send(200, "application/json", res);
  });
  server.begin();
  systemReady = true;
  bootTime = millis();
  Serial.println("SYSTEM READY. LOOP STARTING.");
}

void loop() {
  esp_task_wdt_reset();

  // Highest priority physical buttons
  handleManualButton();

  // Local safety checks
  handleRainLogic();

  if (valveOn && millis() - valveStartTime > MAX_WATER_TIME) {
    if (millis() - lastMsg > 10000) {
      sendTelegram("Safety timeout - watering stopped");
      lastMsg = millis();
    }
    valveClose();
  }

  if (valveOn) {
    if (millis() - bootTime > 15000) {
      if (!isWaterAvailable()) {
        if (millis() - lastMsg > 10000) {
          sendTelegram("Tank became empty - watering stopped");
          lastMsg = millis();
        }

        Serial.println("Tank empty - valve closed, no manual lock");
        valveClose();

        errorCount = 0;
      }
    } else {
      static unsigned long lastGraceMsg = 0;
      if (millis() - lastGraceMsg > 5000) {
        Serial.println("System in stabilization period. Safety checks paused.");
        lastGraceMsg = millis();
      }
    }

    if (nowEpoch() - valveStartEpoch >= activeDuration) {
      valveClose();
    }
  }

  if (!valveOn && tankWasFullAtClose) {
    if (millis() - lastValveCloseTime < 20000) {
      if (!isWaterAvailable()) {
        if (millis() - lastMsg > 10000) {
          sendTelegram("Tank level changed after close");
          lastMsg = millis();
        }

        Serial.println("Tank level changed after close - no manual lock");
        tankWasFullAtClose = false;
      }
    } else {
      tankWasFullAtClose = false;
    }
  }

  handleManualButton();

  // Schedule checks before cloud and MQTT work
  tankHasWater = isWaterAvailable();

  if (tankHasWater) {
    static int lastMinute = -1;
    struct tm timeinfo;

   if (getCachedLocalTime(&timeinfo)) {
   if (timeinfo.tm_min != lastMinute) {
    lastMinute = timeinfo.tm_min;

    int today = timeinfo.tm_wday;

    for (int i = 0; i < SCHEDULE_COUNT; i++) {
      if (!schedules[i].enabled || !schedules[i].days[today] || valveOn) {
        continue;
      }

      if (timeinfo.tm_hour == schedules[i].hour &&
          timeinfo.tm_min == schedules[i].minute) {
        if (nowEpoch() - lastScheduleRunEpoch[i] > 60) {
          lastScheduleRunEpoch[i] = nowEpoch();
          currentLedMode = LED_TRIPLE_FLASH;
          valveOpen(schedules[i].duration);
        }
      }
    }
  }
  }
  }

  handleManualButton();

  // Local interface and services
  handleLED();

  if (!manualButtonPressedNow()) {
    ensureWiFi();
  }

  if (WiFi.status() != WL_CONNECTED) {
    if (wifiLostTime == 0) wifiLostTime = millis();

    if (millis() - wifiLostTime > 600000) {
      Serial.println("Running in OFFLINE mode");
    }
  } else {
    wifiLostTime = 0;
  }

  handleDiscovery();
  ArduinoOTA.handle();
  server.handleClient();

  handleManualButton();

  // Local broadcast and status
  if (millis() - lastBroadcast > 5000) {
    broadcastPresence();
    lastBroadcast = millis();
  }

  broadcastRealtimeSmart();

  handleManualButton();

  // Cloud and MQTT work at the lowest priority
  if (!manualButtonPressedNow()) {
    if (client.connected()) {
      client.loop();
      handleTelegram();
    } else {
      reconnectMQTT();
    }
  }

  if (!cloudNotSafeForBlockingCalls() &&
      millis() - lastWeatherCheck > 1800000) {
    rainForecastCache = isRainExpectedSoon();
  }

  // Housekeeping
  if (millis() > 30000) {
    waterPrefs.putInt("bootCount", 0);
  }

  if (millis() - lastReboot > REBOOT_INTERVAL) {
    ESP.restart();
  }
}
