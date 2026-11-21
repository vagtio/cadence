#!/usr/bin/env python3
"""Mock 音源 backend: signed URL resolution + a real audio file to verify against.

  POST /v1/music/resolve-url   {"source","rid","quality","sign","nonce"} -> {"data":{"url": ...}}
  GET  /audio/track.wav        a 1s 8kHz mono WAV
"""
import hashlib
import json
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
SECRET = b"spike-secret"


def wav_bytes(duration=1.0, rate=8000):
    frames = int(duration * rate)
    data = b"".join(struct.pack("<h", 0) for _ in range(frames))
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
    header += struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    return header + data


AUDIO = wav_bytes()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        sys.stderr.write("[mock] " + (format % args) + "\n")
    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode())
        except Exception:
            return self._json(400, {"code": 400, "msg": "bad json"})

        # Test fixture: mirrors the md5 signing scheme real 音源 scripts use.
        signed = f"{payload.get('rid')}|{payload.get('quality')}|{payload.get('nonce')}|".encode() + SECRET
        expected = hashlib.md5(signed, usedforsecurity=False).hexdigest()
        if payload.get("sign") != expected:
            return self._json(403, {"code": 403, "msg": "bad sign", "expected": expected})

        rid = payload.get("rid", "unknown")
        url = f"http://127.0.0.1:{PORT}/audio/track.wav?rid={rid}&q={payload.get('quality')}"
        self._json(200, {"code": 0, "data": {"url": url, "quality": payload.get("quality")}})

    def do_GET(self):
        if self.path.startswith("/audio/"):
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(AUDIO)))
            self.end_headers()
            self.wfile.write(AUDIO)
            return
        self._json(404, {"code": 404})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"[mock] listening on 127.0.0.1:{PORT}\n")
    server.serve_forever()
