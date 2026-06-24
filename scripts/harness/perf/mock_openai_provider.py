#!/usr/bin/env python3
"""Mock OpenAI-compatible provider for the keeper-load perf harness.

Serves POST /v1/chat/completions with a non-streaming JSON response in the
OpenAI chat.completions shape that agent_sdk's backend_openai_parse.ml reads
(choices[0].message.content + finish_reason + usage). Non-streaming is the
default request path (backend_openai_request.ml: `?(stream = false)`), so the
mock model must be configured with streaming disabled. No SSE required.

Every request is appended (one JSON line) to the --log file so the harness can
prove keepers actually issued provider calls (turn liveness), and count them.

This injects deterministic, network-free keeper compute so the starvation gate
can reproduce the real keeper-vs-serving contention (RFC-0204 §5) instead of
the milder serving-only regime an idle (autonomy=0) boot produces.
"""
import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Assistant reply text. Default is a short "ack" (models provider latency only).
# For the keeper-burst gate, --reply-bytes makes it large: a keeper turn is
# I/O-bound (the provider await yields the main domain), so the real main-domain
# cost is *after* the await — parsing the response and writing the turn record /
# snapshot. A trivial "ack" barely loads the domain even mid-turn; a large,
# realistic body is what makes a resident keeper actually contend with serving.
REPLY_TEXT = "ack"


def build_reply(reply_bytes):
    """Reply text padded to ~reply_bytes so post-await parse/record loads main."""
    if reply_bytes <= len(REPLY_TEXT):
        return REPLY_TEXT
    # Sentence-like filler (not one giant token) so the parse path is realistic.
    filler = "The keeper observes the board and continues its task. "
    body = REPLY_TEXT + " "
    while len(body) < reply_bytes:
        body += filler
    return body[:reply_bytes]


class Handler(BaseHTTPRequestHandler):
    log_path = None
    delay_ms = 0
    reply_text = REPLY_TEXT
    counter = [0]

    def _count(self):
        self.counter[0] += 1
        return self.counter[0]

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        try:
            req = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            req = {}
        n = self._count()
        if self.log_path:
            rec = {
                "ts": time.time(),
                "n": n,
                "path": self.path,
                "model": req.get("model"),
                "stream": req.get("stream", False),
                "n_messages": len(req.get("messages", []) or []),
            }
            try:
                with open(self.log_path, "a") as fh:
                    fh.write(json.dumps(rec) + "\n")
            except Exception:
                pass

        if self.delay_ms > 0:
            time.sleep(self.delay_ms / 1000.0)

        model = req.get("model", "mock-model")
        if req.get("stream", False):
            self._respond_sse(n, model)
        else:
            self._respond_json(n, model)

    def _respond_json(self, n, model):
        body = {
            "id": "chatcmpl-mock-%d" % n,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": self.reply_text},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        payload = json.dumps(body).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _respond_sse(self, n, model):
        # Standard OpenAI chat.completion.chunk SSE frames: one content delta,
        # one finish frame, then the [DONE] sentinel.
        cid = "chatcmpl-mock-%d" % n
        created = int(time.time())

        def chunk(delta, finish):
            return {
                "id": cid,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }

        frames = [
            chunk({"role": "assistant", "content": self.reply_text}, None),
            chunk({}, "stop"),
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for fr in frames:
            self.wfile.write(("data: " + json.dumps(fr) + "\n\n").encode("utf-8"))
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def do_GET(self):
        # health probe convenience
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, format, *args):  # noqa: A002 - match base signature
        pass  # silence default stderr access log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", default=None, help="append one JSON line per request")
    ap.add_argument("--delay-ms", type=int, default=0,
                    help="simulated provider latency per call")
    ap.add_argument("--reply-bytes", type=int, default=0,
                    help="pad the assistant reply to ~N bytes so the keeper's "
                         "post-await parse/record loads the main domain (0 = 'ack')")
    args = ap.parse_args()
    Handler.log_path = args.log
    Handler.delay_ms = args.delay_ms
    Handler.reply_text = build_reply(args.reply_bytes)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write("[mock] listening on 127.0.0.1:%d\n" % args.port)
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
