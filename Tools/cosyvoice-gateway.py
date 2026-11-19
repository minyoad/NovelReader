#!/usr/bin/env python3
"""WAV /v1/audio/speech adapter for an existing CosyVoice installation.
Run from the CosyVoice repository with its Python environment; see Docs/tts-providers.md.
"""
import argparse
import hmac
import io
import json
import math
import os
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def validate_payload(payload, voice):
    if not isinstance(payload, dict):
        raise ValueError("Expected a JSON object")
    text = payload.get("input")
    if not isinstance(text, str) or not text.strip() or len(text) > 4000:
        raise ValueError("input must contain 1-4000 characters")
    if payload.get("model", "cosyvoice") != "cosyvoice":
        raise ValueError("model must be cosyvoice")
    if payload.get("voice", "default") != voice:
        raise ValueError("Unknown voice; use the gateway's configured voice ID")
    if payload.get("response_format", "wav") != "wav":
        raise ValueError("Only WAV is supported")
    speed = payload.get("speed", 1.0)
    if isinstance(speed, bool) or not isinstance(speed, (int, float)) or not math.isfinite(speed) or not 0.5 <= speed <= 2:
        raise ValueError("speed must be between 0.5 and 2")
    return text, speed


def wav_bytes(pcm, sample_rate):
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(sample_rate)
        writer.writeframes(pcm)
    return output.getvalue()


def make_handler(render, voice="default", api_key=""):
    class Handler(BaseHTTPRequestHandler):
        def reply(self, code, body, content_type="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/v1/audio/speech":
                self.reply(404, b'{"error":"Not found"}')
                return
            if api_key and not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + api_key):
                self.reply(401, b'{"error":"Unauthorized"}')
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 64000:
                    raise ValueError("Request body too large or missing Content-Length")
                payload = json.loads(self.rfile.read(size))
                text, speed = validate_payload(payload, voice)
            except (ValueError, UnicodeError):
                self.reply(400, b'{"error":"Invalid request; check model, input, voice, speed and WAV format"}')
                return
            try:
                self.reply(200, render(text, speed), "audio/wav")
            except (BrokenPipeError, ConnectionResetError):
                return
            except Exception:
                self.reply(500, b'{"error":"Synthesis failed; check server model and reference audio"}')

        def setup(self):
            super().setup()
            self.connection.settimeout(120)

        def log_message(self, *_):
            pass  # Do not log novel text, reference audio, or credentials.
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--prompt-wav", required=True)
    parser.add_argument("--prompt-text", required=True, help="Reference transcript; CosyVoice 3 requires its endofprompt prefix")
    parser.add_argument("--voice", default="default")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8880)
    args = parser.parse_args()
    sys.path.insert(0, os.getcwd())
    sys.path.insert(0, os.path.join(os.getcwd(), "third_party", "Matcha-TTS"))
    from cosyvoice.cli.cosyvoice import AutoModel
    import numpy as np
    model = AutoModel(model_dir=args.model_dir)
    lock = threading.Lock()

    def render(text, speed):
        with lock:
            segments = []
            for item in model.inference_zero_shot(text, args.prompt_text, args.prompt_wav, stream=False, speed=speed):
                samples = item["tts_speech"].detach().cpu().numpy().reshape(-1)
                segments.append((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
            pcm = b"".join(segments)
            if not pcm:
                raise RuntimeError("No audio")
            return wav_bytes(pcm, model.sample_rate)

    server = ThreadingHTTPServer((args.host, args.port), make_handler(render, args.voice, os.environ.get("COSYVOICE_API_KEY", "")))
    server.daemon_threads = True
    print(f"CosyVoice gateway ready at {args.host}:{args.port}; voice={args.voice}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
