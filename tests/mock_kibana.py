#!/usr/bin/env python3
"""A tiny stand-in for the bits of the Kibana API the reset script uses.

Implements:
    GET  /api/spaces/space
    GET  [/s/<space>]/api/kibana/settings
    POST [/s/<space>]/api/kibana/settings/<setting key>

Started by tests/run_tests.sh. Prints the port it bound to on stdout.
"""

import base64
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERNAME = "kibana_admin"
PASSWORD = 'p@ss"w\\ord'  # deliberately awkward: quote and backslash

SPACES = [
    {"id": "default", "name": "Default"},
    {"id": "master", "name": "Master"},
    {"id": "analytics", "name": "Analytics"},
]

# space id -> setting key -> user value. "master" and "analytics" start with the
# bad value; "default" has no override at all.
SETTINGS = {
    "default": {},
    "master": {"state:storeInSessionStorage": True},
    "analytics": {"state:storeInSessionStorage": True},
}

SETTINGS_RE = re.compile(r"^(?:/s/([^/]+))?/api/kibana/settings(?:/(.+))?$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep test output readable
        sys.stderr.write("mock-kibana: " + (fmt % args) + "\n")

    # -- helpers ---------------------------------------------------------
    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authenticated(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode()
        except Exception:
            return False
        user, _, password = decoded.partition(":")
        return user == USERNAME and password == PASSWORD

    def _reject_unauthenticated(self):
        if self._authenticated():
            return False
        self._send_json(401, {"statusCode": 401, "message": "missing authentication credentials"})
        return True

    def _space_of(self, path):
        match = SETTINGS_RE.match(path)
        if not match:
            return None, None, False
        space = match.group(1) or "default"
        # Kibana itself does not serve the default space under /s/default.
        if match.group(1) == "default":
            return None, None, False
        if space not in SETTINGS:
            return None, None, False
        return space, match.group(2), True

    # -- verbs -----------------------------------------------------------
    def do_GET(self):
        if self._reject_unauthenticated():
            return
        if self.path == "/api/spaces/space":
            self._send_json(200, SPACES)
            return
        space, key, ok = self._space_of(self.path)
        if ok and key is None:
            settings = {k: {"userValue": v} for k, v in SETTINGS[space].items()}
            self._send_json(200, {"settings": settings})
            return
        self._send_json(404, {"statusCode": 404, "message": "Not Found"})

    def do_POST(self):
        if self._reject_unauthenticated():
            return
        if self.headers.get("kbn-xsrf") is None:
            self._send_json(400, {"statusCode": 400, "message": "Request must contain a kbn-xsrf header."})
            return
        space, key, ok = self._space_of(self.path)
        if not ok or key is None:
            self._send_json(404, {"statusCode": 404, "message": "Not Found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"statusCode": 400, "message": "Bad JSON"})
            return
        if "value" not in payload:
            self._send_json(400, {"statusCode": 400, "message": "'value' is required"})
            return
        value = payload["value"]
        if value is None:
            SETTINGS[space].pop(key, None)  # the UI's "Reset to default"
        else:
            SETTINGS[space][key] = value
        settings = {k: {"userValue": v} for k, v in SETTINGS[space].items()}
        self._send_json(200, {"settings": settings})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
