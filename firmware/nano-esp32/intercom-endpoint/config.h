#pragma once

// Copy this file's WIFI_* / INTERCOM_TOKEN values, or create secrets.h next to
// the sketch (gitignored) with #define WIFI_SSID, WIFI_PASSWORD, INTERCOM_TOKEN.

#if __has_include("secrets.h")
#include "secrets.h"
#endif

#ifndef WIFI_SSID
#define WIFI_SSID "YOUR_WIFI_SSID"
#endif
#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD "YOUR_WIFI_PASSWORD"
#endif

#ifndef INTERCOM_HOST
// LAN IP of the machine running Intercom — not 127.0.0.1 (that is the ESP itself).
#define INTERCOM_HOST "192.168.86.41"
#endif
#define FIRMWARE_CONFIG_TAG "intercom-lan-v8"
#ifndef INTERCOM_PORT
#define INTERCOM_PORT 8090
#endif
#ifndef INTERCOM_WS_PORT
#define INTERCOM_WS_PORT 8093
#endif
#ifndef INTERCOM_TOKEN
#define INTERCOM_TOKEN "dev-device-secret-change-me"
#endif
#ifndef INTERCOM_DEVICE_ID
#define INTERCOM_DEVICE_ID ""
#endif

#define SAMPLE_RATE 24000
#define MAX_RECORD_MS 8000
#define MIN_RECORD_MS 400
#define HEADER_TIMEOUT_MS 120000
#define HTTP_TIMEOUT_MS 15000
#define AUDIO_WAIT_MS HEADER_TIMEOUT_MS

// Silkscreen D# / A0 labels — correct in either IDE pin numbering mode.
#define PIN_MIC_WS D2
#define PIN_MIC_BCLK D3
#define PIN_MIC_SD D4
#define PIN_SPK_WS D5
#define PIN_SPK_BCLK D6
#define PIN_SPK_DIN D7
#define PIN_PTT D8       // to GND, INPUT_PULLUP
#define PIN_AMP_SD D9    // MAX98357A SD (HIGH=on, LOW=mute)
#define PIN_THINK_LED D10
#define THINK_BLINK_MS 250
#define PIN_VOLUME A0    // A50k wiper (ends to 3V3 and GND)
#define ADC_MAX 4095
#define VOL_UPDATE_MS 30

// Mic family — set before flashing when you swap breakouts.
#define MIC_ICS43434 0  // INMP441 and clones use the same I2S timing
#define MIC_SPH0645 1   // Adafruit SPH0645LM4H (ICS-43434 drop-in wiring)
#ifndef MIC_TYPE
#define MIC_TYPE MIC_ICS43434
#endif

// SEL/L/R tied to GND => left slot. Set 0 if SEL is tied to 3V3.
#define MIC_LEFT_SLOT 1

// Log mic pin map + OUT activity on every PTT capture.
#ifndef MIC_PTT_PIN_DEBUG
#define MIC_PTT_PIN_DEBUG 1
#endif
