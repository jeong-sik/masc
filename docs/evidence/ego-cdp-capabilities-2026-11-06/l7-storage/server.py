"""L7 probe server: sets test cookies with response headers, which document.cookie cannot (HttpOnly)."""
import http.server
import sys

PAGE = b"""<!doctype html><meta charset=utf-8><title>l7</title><p>storage probe</p>
<script>
window.frameCookies = [];
addEventListener("message", (event) => { window.frameCookies.push(event.data); });
window.addFrame = (src) => new Promise((resolve) => {
  const frame = document.createElement("iframe");
  frame.onload = () => resolve(true);
  frame.src = src;
  document.body.appendChild(frame);
});
</script>"""

FRAME = b"""<!doctype html><meta charset=utf-8><p>frame</p>
<script>parent.postMessage({frameCookieNames: document.cookie.split("; ").filter(Boolean).map((pair) => pair.split("=")[0])}, "*");</script>"""

COOKIES = {
    "/set": [
        "masc_l7_http=HTTP_SECRET_VALUE; Path=/; HttpOnly; SameSite=Strict",
        "masc_l7_persist=PERSIST_SECRET_VALUE; Path=/; Max-Age=600",
        "masc_l7_sub=SUB_SECRET_VALUE; Path=/sub",
    ],
    "/setframe": ["masc_l7_frame=FRAME_SECRET_VALUE; Path=/"],
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        body = FRAME if path == "/frame.html" else PAGE
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        for cookie in COOKIES.get(path, []):
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), format % args))


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
