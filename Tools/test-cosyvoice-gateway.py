import importlib.util
import io
import pathlib
import unittest
import wave
import threading
import urllib.request
import urllib.error
import json
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("gateway", pathlib.Path(__file__).with_name("cosyvoice-gateway.py"))
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)

class GatewayTests(unittest.TestCase):
    def test_valid_request_and_rate(self):
        self.assertEqual(gateway.validate_payload({"input": "你好", "voice": "default", "speed": 1.5}, "default"), ("你好", 1.5))

    def test_invalid_protocol_fields(self):
        for patch in [{"input": ""}, {"input": "字" * 4001}, {"voice": "unknown"}, {"model": "wrong"}, {"response_format": "mp3"}, {"speed": float("nan")}, {"speed": True}, {"speed": "1"}]:
            with self.assertRaises(ValueError):
                gateway.validate_payload({"input": "你好", **patch}, "default")

    def test_http_auth_validation_and_audio(self):
        audio = gateway.wav_bytes(b"\x00\x00" * 24, 24000)
        requests = []
        def render(text, speed):
            requests.append((text, speed))
            return audio
        server = ThreadingHTTPServer(("127.0.0.1", 0), gateway.make_handler(render, api_key="test-key"))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            url = "http://127.0.0.1:%d/v1/audio/speech" % server.server_port
            def request(payload, key="test-key"):
                return urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request({"input": "你好"}, "bad"))
            self.assertEqual(error.exception.code, 401)
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request({"input": "你好", "voice": "unknown"}))
            self.assertEqual(error.exception.code, 400)
            with urllib.request.urlopen(request({"input": "你好", "speed": 1.25})) as response:
                self.assertEqual(response.headers["Content-Type"], "audio/wav")
                self.assertEqual(response.read(), audio)
            self.assertEqual(requests, [("你好", 1.25)])
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_wav_sample_rate_and_frame_integrity(self):
        pcm = b"\x01\x00" * 24
        with wave.open(io.BytesIO(gateway.wav_bytes(pcm, 24000)), "rb") as reader:
            self.assertEqual(reader.getframerate(), 24000)
            self.assertEqual(reader.getnchannels(), 1)
            self.assertEqual(reader.getsampwidth(), 2)
            self.assertEqual(reader.readframes(24), pcm)

if __name__ == "__main__":
    unittest.main()
