"""Mock of the Mergin Maps API endpoints used for workspace browsing, for an account in several workspaces
(as on app.merginmaps.com / Enterprise Edition; Community Edition always has a single workspace).

Responses follow the shapes of a real Mergin server (2025.x). Only listing is mocked: no downloads or sync.
Usage: python -I mock_multi_workspace.py [port]   (default 5055; user "sarah" / "Sarah-Pass-123")
"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = "mock-token"
WORKSPACES = [
    {"id": 1, "name": "documentation", "role": "reader", "disk_usage": 52_428_800, "storage": 524_288_000, "project_count": 2},
    {"id": 2, "name": "my-team", "role": "owner", "disk_usage": 5_347_737, "storage": 524_288_000, "project_count": 3},
    {"id": 3, "name": "sarah", "role": "owner", "disk_usage": 1_048_576, "storage": 104_857_600, "project_count": 1},
]
PROJECTS = {
    "documentation": [("survey-template", "v12", 2_400_000), ("land-use-demo", "v4", 9_800_000)],
    "my-team": [("A walk along the river", "v7", 1_200_000), ("trees-and-hedges", "v3", 3_100_000), ("street-lights", "v21", 800_000)],
    "sarah": [("my-survey", "v2", 120_000)],
}


def project_json(ns, name, version, size, i):
    return {"id": f"00000000-0000-0000-0000-{abs(hash(ns + name)) % 10**12:012d}", "name": name, "namespace": ns,
            "version": version, "disk_usage": size, "created": "2026-09-01T10:00:00Z",
            "updated": f"2026-10-2{2 - min(i, 2)}T{8 + i:02d}:15:00Z", "access": {}, "permissions": {"delete": True, "update": True, "upload": True},
            "tags": ["valid_qgis", "input_use"], "creator": 1, "has_conflict": False}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorised(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {"detail": "Authentication information is missing or invalid."})
            return False
        return True

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/config":
            return self._send(200, {"major": 2025, "minor": 7, "fix": 3, "version": "2025.7.3", "server_type": "ee", "sso_enabled": False})
        if not self._authorised():
            return
        if url.path == "/v1/user/profile":
            return self._send(200, {"username": "sarah", "email": "sarah@example.com", "name": "Sarah Okoro", "preferred_workspace": 2,
                                    "workspaces": [{"id": w["id"], "name": w["name"], "role": w["role"]} for w in WORKSPACES]})
        if url.path == "/v1/workspaces":
            return self._send(200, WORKSPACES)
        if url.path == "/v1/project/paginated":
            ns = q.get("only_namespace", [None])[0]
            items = [project_json(n, *p, i) for n, ps in PROJECTS.items() if ns in (None, n) for i, p in enumerate(ps)]
            name = q.get("name", [None])[0]
            if name:
                items = [p for p in items if name.lower() in p["name"].lower()]
            return self._send(200, {"count": len(items), "projects": items})
        self._send(404, {"detail": "Not found"})

    def do_POST(self):
        if urlparse(self.path).path == "/v1/auth/login":
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if body.get("login") in ("sarah", "sarah@example.com") and body.get("password") == "Sarah-Pass-123":
                return self._send(200, {"username": "sarah", "email": "sarah@example.com",
                                        "session": {"token": TOKEN, "expire": "2099-01-01T00:00:00+00:00"}})
            return self._send(401, {"detail": "Invalid username or password"})
        self._send(404, {"detail": "Not found"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5055
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
