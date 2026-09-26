#!/usr/bin/env python3
"""Local UI smoke-test fixture. Never a production model or translation engine.

Run manually, configure Sayo with the printed loopback URL and model `ui-fixture`,
then use only the documented sample. Clear temporary model settings after testing.
Requests and keys are not logged.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > 128000:
            self.send_error(413)
            return
        data = json.loads(self.rfile.read(length))
        if (self.path != "/v1/chat/completions" or data.get("model") != "ui-fixture"
                or data.get("messages", [{}])[-1].get("content") != "I like 这个产品"):
            self.send_error(400, "This fixture only accepts the documented sample")
            return
        time.sleep(1)
        body = json.dumps({"choices": [{"message": {"content": "I like this product."}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(f"UI fixture only: http://127.0.0.1:{server.server_port}/v1", flush=True)
    server.serve_forever()
