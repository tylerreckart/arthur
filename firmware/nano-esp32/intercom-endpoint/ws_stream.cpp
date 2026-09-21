#include "ws_stream.h"

#include <esp_random.h>
#include <string.h>

namespace {

constexpr const char *kWsMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
constexpr uint32_t kConnectMs = 15000;
constexpr uint32_t kHeaderMs = 5000;

uint32_t rol32(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

void sha1_20(const uint8_t *data, size_t len, uint8_t out[20]) {
  uint32_t h0 = 0x67452301u, h1 = 0xEFCDAB89u, h2 = 0x98BADCFEu, h3 = 0x10325476u,
           h4 = 0xC3D2E1F0u;
  uint8_t block[64];
  const uint64_t bit_len = (uint64_t)len * 8;
  size_t off = 0;
  auto process = [&](const uint8_t *m) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
      w[i] = ((uint32_t)m[i * 4] << 24) | ((uint32_t)m[i * 4 + 1] << 16) |
             ((uint32_t)m[i * 4 + 2] << 8) | (uint32_t)m[i * 4 + 3];
    }
    for (int i = 16; i < 80; ++i) w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
    for (int i = 0; i < 80; ++i) {
      uint32_t f, k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5A827999u;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1u;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDCu;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6u;
      }
      const uint32_t temp = rol32(a, 5) + f + e + k + w[i];
      e = d;
      d = c;
      c = rol32(b, 30);
      b = a;
      a = temp;
    }
    h0 += a;
    h1 += b;
    h2 += c;
    h3 += d;
    h4 += e;
  };

  while (off + 64 <= len) {
    process(data + off);
    off += 64;
  }
  const size_t rem = len - off;
  memcpy(block, data + off, rem);
  block[rem] = 0x80;
  if (rem + 1 <= 56) {
    memset(block + rem + 1, 0, 56 - rem - 1);
  } else {
    memset(block + rem + 1, 0, 64 - rem - 1);
    process(block);
    memset(block, 0, 56);
  }
  for (int i = 0; i < 8; ++i) block[56 + i] = (uint8_t)((bit_len >> ((7 - i) * 8)) & 0xff);
  process(block);

  const uint32_t hs[5] = {h0, h1, h2, h3, h4};
  for (int i = 0; i < 5; ++i) {
    out[i * 4] = (uint8_t)((hs[i] >> 24) & 0xff);
    out[i * 4 + 1] = (uint8_t)((hs[i] >> 16) & 0xff);
    out[i * 4 + 2] = (uint8_t)((hs[i] >> 8) & 0xff);
    out[i * 4 + 3] = (uint8_t)(hs[i] & 0xff);
  }
}

bool b64_encode(const uint8_t *src, size_t slen, char *dst, size_t dst_cap) {
  static const char tbl[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const size_t need = ((slen + 2) / 3) * 4;
  if (need + 1 > dst_cap) return false;
  size_t o = 0, i = 0;
  while (i < slen) {
    const uint32_t n = ((uint32_t)src[i] << 16) |
                       (i + 1 < slen ? (uint32_t)src[i + 1] << 8 : 0) |
                       (i + 2 < slen ? (uint32_t)src[i + 2] : 0);
    dst[o++] = tbl[(n >> 18) & 63];
    dst[o++] = tbl[(n >> 12) & 63];
    dst[o++] = i + 1 < slen ? tbl[(n >> 6) & 63] : '=';
    dst[o++] = i + 2 < slen ? tbl[n & 63] : '=';
    i += 3;
  }
  dst[o] = 0;
  return true;
}

void make_ws_key(char out[29]) {
  uint8_t raw[16];
  esp_fill_random(raw, sizeof(raw));
  b64_encode(raw, sizeof(raw), out, 29);
}

bool expected_accept(const char *client_key, char out[29]) {
  char concat[64];
  const int n = snprintf(concat, sizeof(concat), "%s%s", client_key, kWsMagic);
  if (n <= 0 || n >= (int)sizeof(concat)) return false;
  uint8_t hash[20];
  sha1_20(reinterpret_cast<const uint8_t *>(concat), (size_t)n, hash);
  return b64_encode(hash, sizeof(hash), out, 29);
}

int header_name_eq(const String &line, const char *name) {
  const int colon = line.indexOf(':');
  if (colon < 0) return -1;
  String got = line.substring(0, colon);
  got.trim();
  got.toLowerCase();
  String want = name;
  want.toLowerCase();
  if (got != want) return -1;
  return colon;
}

}  // namespace

bool IntercomWs::readExact(uint8_t *dst, size_t n, uint32_t timeout_ms) {
  size_t got = 0;
  const uint32_t start = millis();
  while (got < n) {
    if (millis() - start > timeout_ms) return false;
    const int avail = c_.available();
    if (avail > 0) {
      const int r = c_.read(dst + got, min((size_t)avail, n - got));
      if (r > 0) got += (size_t)r;
    } else if (!c_.connected()) {
      return false;
    } else {
      delay(1);
    }
  }
  return true;
}

bool IntercomWs::sendFrame(uint8_t opcode, const uint8_t *data, size_t len) {
  if (!c_.connected()) return false;
  if (len > 0xffff) return false;

  uint8_t hdr[8];
  size_t hlen = 2;
  hdr[0] = 0x80 | (opcode & 0x0f);
  if (len < 126) {
    hdr[1] = 0x80 | (uint8_t)len;
  } else {
    hdr[1] = 0x80 | 126;
    hdr[2] = (uint8_t)((len >> 8) & 0xff);
    hdr[3] = (uint8_t)(len & 0xff);
    hlen = 4;
  }

  uint8_t mask[4];
  const uint32_t r = esp_random();
  mask[0] = (uint8_t)r;
  mask[1] = (uint8_t)(r >> 8);
  mask[2] = (uint8_t)(r >> 16);
  mask[3] = (uint8_t)(r >> 24);
  memcpy(hdr + hlen, mask, 4);
  hlen += 4;

  if (c_.write(hdr, hlen) != hlen) return false;

  uint8_t tmp[256];
  size_t off = 0;
  while (off < len) {
    const size_t n = min(len - off, sizeof(tmp));
    for (size_t i = 0; i < n; ++i) {
      tmp[i] = data[off + i] ^ mask[(off + i) & 3];
    }
    if (c_.write(tmp, n) != n) return false;
    off += n;
    yield();
  }
  return true;
}

bool IntercomWs::sendBinary(const uint8_t *data, size_t len) {
  return sendFrame(0x02, data, len);
}

bool IntercomWs::sendText(const char *json) {
  if (!json) return false;
  return sendFrame(0x01, reinterpret_cast<const uint8_t *>(json), strlen(json));
}

bool IntercomWs::sendPing() { return sendFrame(0x09, nullptr, 0); }

bool IntercomWs::sendPong(const uint8_t *data, size_t len) {
  return sendFrame(0x0a, data, len);
}

bool IntercomWs::sendClose() { return sendFrame(0x08, nullptr, 0); }

bool IntercomWs::readable() { return c_.connected() && c_.available() > 0; }

void IntercomWs::close() {
  if (c_.connected()) {
    sendClose();
    delay(10);
  }
  c_.stop();
}

bool IntercomWs::connectUpgrade(const char *host, uint16_t port, const char *token,
                               const char *device_id) {
  close();
  IPAddress ip;
  if (!ip.fromString(host)) {
    Serial.printf("ws: bad host %s\n", host);
    return false;
  }
  c_.setTimeout(kConnectMs);
  c_.setNoDelay(true);
  if (!c_.connect(ip, port, kConnectMs)) {
    Serial.printf("ws: connect failed %s:%u\n", host, (unsigned)port);
    return false;
  }

  char key[29];
  make_ws_key(key);
  c_.printf("GET /v1/stream HTTP/1.1\r\n");
  c_.printf("Host: %s:%u\r\n", host, (unsigned)port);
  c_.print("Upgrade: websocket\r\n");
  c_.print("Connection: Upgrade\r\n");
  c_.printf("Sec-WebSocket-Key: %s\r\n", key);
  c_.print("Sec-WebSocket-Version: 13\r\n");
  c_.printf("Authorization: Bearer %s\r\n", token);
  c_.printf("X-Device-Id: %s\r\n", device_id);
  c_.print("\r\n");
  c_.flush();

  String line;
  const uint32_t t0 = millis();
  auto readLine = [&](String &out) -> bool {
    out = "";
    while (millis() - t0 < kHeaderMs) {
      while (c_.available()) {
        const char ch = (char)c_.read();
        if (ch == '\n') {
          if (out.endsWith("\r")) out.remove(out.length() - 1);
          return true;
        }
        out += ch;
        if (out.length() > 1024) return false;
      }
      if (!c_.connected() && !c_.available()) return false;
      delay(1);
    }
    return false;
  };

  if (!readLine(line) || line.indexOf("101") < 0) {
    Serial.printf("ws: handshake %s\n", line.c_str());
    close();
    return false;
  }

  char want[29];
  if (!expected_accept(key, want)) {
    close();
    return false;
  }
  bool got_accept = false;
  for (;;) {
    if (!readLine(line)) {
      close();
      return false;
    }
    if (line.length() == 0) break;
    const int colon = header_name_eq(line, "Sec-WebSocket-Accept");
    if (colon < 0) continue;
    String value = line.substring(colon + 1);
    value.trim();
    if (value == want) got_accept = true;
  }
  if (!got_accept) {
    Serial.println("ws: bad Sec-WebSocket-Accept");
    close();
    return false;
  }
  return true;
}

bool IntercomWs::waitReady(uint32_t timeout_ms) {
  uint8_t buf[256];
  size_t n = 0;
  const uint32_t t0 = millis();
  while (millis() - t0 < timeout_ms) {
    const Kind k = recv(buf, sizeof(buf) - 1, &n, 250);
    if (k == Kind::Timeout) continue;
    if (k == Kind::Ping) {
      sendPong(buf, n);
      continue;
    }
    if (k == Kind::Pong) continue;
    if (k != Kind::Text) {
      close();
      return false;
    }
    buf[n < sizeof(buf) ? n : sizeof(buf) - 1] = 0;
    if (strstr(reinterpret_cast<char *>(buf), "\"ready\"")) return true;
    Serial.printf("ws: unexpected %s\n", reinterpret_cast<char *>(buf));
    close();
    return false;
  }
  Serial.println("ws: no ready");
  close();
  return false;
}

bool IntercomWs::ensure(const char *host, uint16_t port, const char *token,
                       const char *device_id) {
  if (port == 0) return false;
  if (c_.connected()) return true;
  if (!connectUpgrade(host, port, token, device_id)) return false;
  if (!waitReady(3000)) return false;
  Serial.printf("ws: up %s:%u\n", host, (unsigned)port);
  return true;
}

IntercomWs::Kind IntercomWs::recvHeader(size_t *payload_len, uint32_t timeout_ms) {
  if (payload_len) *payload_len = 0;
  if (rx_left_ && !discardPayload(timeout_ms)) return Kind::Error;
  if (!c_.connected()) return Kind::Error;

  uint8_t hdr[2];
  if (!readExact(hdr, 2, timeout_ms)) {
    return c_.connected() ? Kind::Timeout : Kind::Error;
  }
  const uint8_t opcode = hdr[0] & 0x0f;
  rx_masked_ = (hdr[1] & 0x80) != 0;
  uint64_t plen = hdr[1] & 0x7f;
  if (plen == 126) {
    uint8_t ext[2];
    if (!readExact(ext, 2, timeout_ms)) return Kind::Error;
    plen = ((uint64_t)ext[0] << 8) | ext[1];
  } else if (plen == 127) {
    uint8_t ext[8];
    if (!readExact(ext, 8, timeout_ms)) return Kind::Error;
    plen = 0;
    for (int i = 0; i < 8; ++i) plen = (plen << 8) | ext[i];
  }
  if (rx_masked_ && !readExact(rx_mask_, 4, timeout_ms)) return Kind::Error;
  rx_left_ = (size_t)plen;
  rx_off_ = 0;
  if (payload_len) *payload_len = rx_left_;

  switch (opcode) {
    case 0x01:
      return Kind::Text;
    case 0x02:
      return Kind::Binary;
    case 0x08:
      return Kind::Close;
    case 0x09:
      return Kind::Ping;
    case 0x0a:
      return Kind::Pong;
    default:
      return Kind::Error;
  }
}

bool IntercomWs::recvPayload(uint8_t *dst, size_t n, uint32_t timeout_ms) {
  if (n > rx_left_) n = rx_left_;
  if (n && !readExact(dst, n, timeout_ms)) return false;
  if (rx_masked_) {
    for (size_t i = 0; i < n; ++i) dst[i] ^= rx_mask_[(rx_off_ + i) & 3];
  }
  rx_off_ += n;
  rx_left_ -= n;
  return true;
}

bool IntercomWs::discardPayload(uint32_t timeout_ms) {
  uint8_t drop[64];
  while (rx_left_ > 0) {
    const size_t n = min(rx_left_, sizeof(drop));
    if (!recvPayload(drop, n, timeout_ms)) return false;
  }
  return true;
}

IntercomWs::Kind IntercomWs::recv(uint8_t *buf, size_t cap, size_t *len,
                                 uint32_t timeout_ms, bool *truncated) {
  if (len) *len = 0;
  if (truncated) *truncated = false;
  size_t plen = 0;
  const Kind k = recvHeader(&plen, timeout_ms);
  if (k == Kind::Timeout || k == Kind::Error) return k;
  const size_t copy = min(plen, cap);
  if (copy && !recvPayload(buf, copy, timeout_ms)) return Kind::Error;
  if (rx_left_) {
    if (truncated) *truncated = true;
    if (!discardPayload(timeout_ms)) return Kind::Error;
  }
  if (len) *len = copy;
  return k;
}
