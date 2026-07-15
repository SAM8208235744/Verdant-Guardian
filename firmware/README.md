# ESP32 firmware

The `verdant_controller` sketch runs the local watering controller. It prioritizes physical buttons and safety checks before network work, stores settings in ESP32 preferences, and continues operating when MQTT or the internet is unavailable.

## Prepare the sketch

1. Install the ESP32 board package in Arduino IDE.
2. Install ArduinoJson, PubSubClient, and UniversalTelegramBot from Library Manager.
3. Copy `verdant_controller/config.example.h` to `verdant_controller/config.h`.
4. Fill in Wi-Fi and any optional service settings in `config.h`.
5. Select **ESP32 Dev Module**, choose the correct serial port, compile, and upload.

`config.h` is deliberately ignored by Git. Empty MQTT, weather, Telegram, OTA, and bridge settings disable those optional integrations.

## Wiring checklist

| Function | Pin | Expected behavior |
| --- | ---: | --- |
| Relay | GPIO 25 | Active low |
| Status LED | GPIO 2 | High while watering |
| RGB red | GPIO 14 | PWM output |
| RGB green | GPIO 27 | PWM output |
| RGB blue | GPIO 33 | PWM output |
| On button | GPIO 5 | Active low with internal pull-up |
| Off button | GPIO 26 | Active low with internal pull-up |
| Float sensor | GPIO 32 | Active low when water is available |
| Rain sensor | GPIO 4 | Active low when wet |

Verify your sensor modules and relay board use the expected logic levels before powering the valve or pump.

## Physical controls

- Press **On** to start the default manual watering duration.
- Press **Off** to stop watering.
- Hold **Off** for three seconds to stop watering and engage the manual lock.
- Hold **On** for three seconds to release the manual lock.

## First-run checks

1. Upload with the relay load disconnected.
2. Confirm the relay remains off during boot and OTA updates.
3. Confirm both buttons work even when Wi-Fi and MQTT are unavailable.
4. Confirm an empty-tank signal stops watering.
5. Confirm the rain input stops watering and applies a delay.
6. Reconnect the valve or pump only after all dry tests pass.
