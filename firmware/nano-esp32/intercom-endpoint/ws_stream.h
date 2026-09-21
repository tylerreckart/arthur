#pragma once

#include <Arduino.h>
#include <WiFi.h>

// Live PTT PCM sink. Defined here so Arduino's generated .ino prototypes
// see the type (they are inserted after #includes, before the sketch body).
struct RecordStream {
  bool (*send)(const int16_t *samples, size_t n, void *ctx);
  void *ctx = nullptr;
  bool ok = true;
  size_t sent = 0;
};

// Minimal RFC 6455 client for Intercom `GET /v1/stream`.
// Masks outbound frames; plays unmasked inbound binary PCM as it arrives.
class IntercomWs {
 public:
  enum class Kind { Timeout, Error, Text, Binary, Ping, Pong, Close };

  bool ensure(const char *host, uint16_t port, const char *token,
              const char *device_id);
  void close();
  // WiFiClient::connected() is non-const on arduino-esp32 2.0.x.
  bool connected() { return c_.connected(); }

  bool sendBinary(const uint8_t *data, size_t len);
  bool sendText(const char *json);
  bool sendPing();
  bool sendPong(const uint8_t *data, size_t len);
  bool sendClose();
  bool readable();

  // Read the next frame header. Call recvPayload / discardPayload next.
  Kind recvHeader(size_t *payload_len, uint32_t timeout_ms);
  bool recvPayload(uint8_t *dst, size_t n, uint32_t timeout_ms);
  bool discardPayload(uint32_t timeout_ms);

  // Convenience: copy the next payload into `buf` (truncate + discard tail).
  Kind recv(uint8_t *buf, size_t cap, size_t *len, uint32_t timeout_ms,
            bool *truncated = nullptr);

 private:
  bool connectUpgrade(const char *host, uint16_t port, const char *token,
                      const char *device_id);
  bool sendFrame(uint8_t opcode, const uint8_t *data, size_t len);
  bool readExact(uint8_t *dst, size_t n, uint32_t timeout_ms);
  bool waitReady(uint32_t timeout_ms);

  WiFiClient c_;
  size_t rx_left_ = 0;
  size_t rx_off_ = 0;
  bool rx_masked_ = false;
  uint8_t rx_mask_[4] = {0, 0, 0, 0};
};
