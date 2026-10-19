#!/usr/bin/env python3
"""A tiny stand-in for the bits of the Kibana API the reset script uses.

Implements:
    GET  /api/spaces/space
    GET  [/s/<space>]/api/kibana/settings
    POST [/s/<space>]/api/kibana/settings/<setting key>

Accepts HTTP Basic auth (USERNAME / PASSWORD) or an API key
(``Authorization: ApiKey <API_KEY>``).

A path prefix switches the server into a misbehaving mode, to exercise the
script's error handling against things a real deployment can do:

    /bogus/...     settings reads return 200 with ``{}`` (no settings object)
    /html/...      settings reads return 200 with an HTML page (e.g. an SSO
                   login page in front of Kibana)
    /redirect/...  every request is answered with a 302 to another host
    /slow/...      every request waits SLOW_SECONDS before being answered
                   normally (to exercise timeouts)

Started by tests/run_tests.sh. Prints the port it bound to on stdout.
"""

import base64
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERNAME = "kibana_admin"
PASSWORD = 'p@ss"w\\ord'  # deliberately awkward: quote and backslash
API_KEY = base64.b64encode(b"test-key-id:test-key-secret").decode()

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
MODES = ("/bogus", "/html", "/redirect", "/slow")
SLOW_SECONDS = 5
HTML_PAGE = "<html>\n\t<head><title>Sign in</title></head>\n\t<body>\tPlease log in</body>\n</html>\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep test output readable
        sys.stderr.write("mock-kibana: " + (fmt % args) + "\n")

    # -- helpers ---------------------------------------------------------
    def _send(self, status, body, content_type, extra_headers=None):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, status, payload):
        self._send(status, json.dumps(payload), "application/json")

    def _split_mode(self):
        for mode in MODES:
            if self.path == mode or self.path.startswith(mode + "/"):
                return mode, self.path[len(mode):] or "/"
        return None, self.path

    def _authenticated(self):
        header = self.headers.get("Authorization", "")
        if header == "ApiKey " + API_KEY:
            return True
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
        self._send_json(401, {"statusCode": 401, "error": "Unauthorized",
                              "message": "missing authentication credentials"})
        return True

    def _redirect(self, path):
        self._send(302, "", "text/plain", {"Location": "https://elsewhere.example" + path})

    @staticmethod
    def _space_of(path):
        match = SETTINGS_RE.match(path)
        if not match:
            return None, None, False
        # Kibana itself does not serve the default space under /s/default.
        if match.group(1) == "default":
            return None, None, False
        space = match.group(1) or "default"
        if space not in SETTINGS:
            return None, None, False
        return space, match.group(2), True

    # -- verbs -----------------------------------------------------------
    def do_GET(self):
        mode, path = self._split_mode()
        if mode == "/slow":
            time.sleep(SLOW_SECONDS)
        if mode == "/redirect":
            self._redirect(path)
            return
        if self._reject_unauthenticated():
            return
        if path == "/api/spaces/space":
            self._send_json(200, SPACES)
            return
        space, key, ok = self._space_of(path)
        if ok and key is None:
            if mode == "/bogus":
                self._send_json(200, {})
            elif mode == "/html":
                self._send(200, HTML_PAGE, "text/html")
            else:
                settings = {k: {"userValue": v} for k, v in SETTINGS[space].items()}
                self._send_json(200, {"settings": settings})
            return
        self._send_json(404, {"statusCode": 404, "message": "Not Found"})

    def do_POST(self):
        mode, path = self._split_mode()
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if mode == "/redirect":
            self._redirect(path)
            return
        if self._reject_unauthenticated():
            return
        if mode not in (None, "/slow"):  # misbehaving modes never accept writes
            self._send_json(500, {"statusCode": 500, "message": "mode does not accept writes"})
            return
        if self.headers.get("kbn-xsrf") is None:
            self._send_json(400, {"statusCode": 400, "message": "Request must contain a kbn-xsrf header."})
            return
        space, key, ok = self._space_of(path)
        if not ok or key is None:
            self._send_json(404, {"statusCode": 404, "message": "Not Found"})
            return
        try:
            payload = json.loads(raw or b"{}")
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
