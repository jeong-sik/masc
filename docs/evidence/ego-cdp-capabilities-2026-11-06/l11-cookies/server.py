"""L11 probe server: a page that reads document.cookie on demand and an echo of the masc_l11_ cookies a request carried."""
import http.server
import json
import sys

PAGE = b"""<!doctype html><meta charset=utf-8><title>l11</title><p>cookie probe</p>
<script>
window.seen = () => document.cookie.split("; ").filter((part) => part.startsWith("masc_l11_")).sort();
window.echo = (path) => fetch(path || "/echo").then((response) => response.json());
</script>"""

PREFIX = "masc_l11_"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        if path.endswith("/echo"):
            parts = [part.strip() for part in (self.headers.get("Cookie") or "").split(";")]
            body = json.dumps(sorted(part for part in parts if part.startswith(PREFIX))).encode()
            kind = "application/json"
        elif path in ("/", "/page", "/sub/page"):
            body, kind = PAGE, "text/html; charset=utf-8"
        else:
            body, kind = b"x", "text/plain"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
