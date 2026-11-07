"""L8 probe server: a page that sends requests on demand, a redirect, a slow answer and a frame that fetches."""
import http.server
import sys
import time

PAGE = b"""<!doctype html><meta charset=utf-8><title>l8</title><p>network probe</p>
<script>
window.frameDone = [];
addEventListener("message", (event) => { window.frameDone.push(event.data); });
window.fire = async (count, prefix, batch = 100) => {
  let ok = 0, failed = 0;
  for (let start = 0; start < count; start += batch) {
    const round = [];
    for (let index = start; index < Math.min(count, start + batch); index++)
      round.push(fetch(`/x?tag=${prefix}&i=${index}&token=L8_SECRET_QUERY`, {headers: {"X-Masc-L8": "L8_SECRET_HEADER"}})
        .then((r) => r.text()).then(() => ok++, () => failed++));
    await Promise.all(round);
  }
  return {ok, failed};
};
window.addFrame = (src) => new Promise((resolve) => {
  const frame = document.createElement("iframe");
  frame.onload = () => resolve(true);
  frame.src = src;
  document.body.appendChild(frame);
});
</script>"""

FRAME = b"""<!doctype html><meta charset=utf-8><p>frame</p>
<script>fetch("/x?tag=frame&token=L8_SECRET_QUERY").then((r) => r.text()).then(() => parent.postMessage("frame-fetched", "*"));</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        if path == "/redir":
            self.send_response(302)
            self.send_header("Location", "/x?tag=redirected&token=L8_SECRET_QUERY")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if path == "/slow":
            time.sleep(2)
        body, kind = (FRAME, "text/html") if path == "/frame.html" else (PAGE, "text/html") if path in ("/", "/page") else (b"x", "text/plain")
        self.send_response(200)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Masc-L8-Answer", "L8_SECRET_ANSWER")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
