"""L9 probe server: a page that writes console lines on load and on demand, throws, and holds two frames."""
import http.server
import sys

PAGE = b"""<!doctype html><meta charset=utf-8><title>l9</title><p>console probe</p>
<script>
console.log("load-line", 7, {kind: "load"});
console.warn("load-warn");
console.error("load-error");
setTimeout(() => { throw new Error("load-uncaught"); }, 0);
Promise.reject(new Error("load-rejected"));
window.say = (count, tag) => { for (let index = 0; index < count; index++) console.log(tag + "-" + index); return count; };
window.throwLater = (tag) => { setTimeout(() => { throw new Error(tag); }, 0); return true; };
window.addFrame = (src) => new Promise((resolve) => {
  const frame = document.createElement("iframe");
  frame.onload = () => resolve(true);
  frame.src = src;
  document.body.appendChild(frame);
});
</script>"""

FRAME = b"""<!doctype html><meta charset=utf-8><p>frame</p><script>console.log("frame-line " + location.host);</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        body = FRAME if path == "/frame.html" else PAGE if path in ("/", "/page") else b"x"
        kind = "text/html" if path in ("/", "/page", "/frame.html") else "text/plain"
        self.send_response(200)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
