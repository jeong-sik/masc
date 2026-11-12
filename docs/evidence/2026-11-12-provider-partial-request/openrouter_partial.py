"""RFC-0492 section 6 test 5 against OpenRouter (openrouter.ai).

Sends a request's headers and the front part of its body, then ends the TCP
connection with a FIN (no TLS close_notify), and reads whatever the server
answers. A server that treats the cut-off request as complete would answer
200 with a completion or usage; that provider then gets no layer 8.

The API key comes from OPENROUTER_API_KEY and is never printed or logged.

  python3 glm_partial.py quota   -> print the usage windows once
  python3 glm_partial.py run     -> control request, 4 partial requests, usage before/after
  python3 glm_partial.py stall   -> two cut-off requests that keep the connection open and wait for an answer
  python3 glm_partial.py control-fin -> the whole request, then FIN: does a half-closed client still get its answer
"""

import json
import os
import socket
import ssl
import sys
import time

HOST = "openrouter.ai"
PORT = 443
CHAT_PATH = "/api/v1/chat/completions"
QUOTA_PATH = "/api/monitor/usage/quota/limit"
MODEL = "nvidia/nemotron-3.5-super-vl:free"
CONNECT_TIMEOUT_S = 10.0
READ_TIMEOUT_S = 20.0
PAUSE_BETWEEN_S = 2.0
STALL_WAIT_S = 70.0
SNIPPET_CHARS = 200


def api_key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key:
        sys.exit("OPENROUTER_API_KEY is not set")
    return key


class TlsConn:
    """TLS over a socket whose TCP write side can be shut down separately."""

    def __init__(self) -> None:
        self.server_ended = False
        self.server_reset = False
        self.first_byte_s: float | None = None
        self.opened_at = time.monotonic()
        self.sock = socket.create_connection((HOST, PORT), timeout=CONNECT_TIMEOUT_S)
        ctx = ssl.create_default_context()
        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.tls = ctx.wrap_bio(self.incoming, self.outgoing, server_hostname=HOST)
        self.sock.settimeout(READ_TIMEOUT_S)
        while True:
            try:
                self.tls.do_handshake()
                break
            except ssl.SSLWantReadError:
                self._flush()
                self._feed()
        self._flush()

    def _flush(self) -> None:
        data = self.outgoing.read()
        if data:
            self.sock.sendall(data)

    def _feed(self) -> bool:
        """Read ciphertext from the socket. False when the peer ended the stream."""
        try:
            data = self.sock.recv(65536)
        except (socket.timeout, TimeoutError):
            return False
        except (ConnectionResetError, BrokenPipeError):
            self.server_ended = True
            self.server_reset = True
            self.incoming.write_eof()
            return False
        if data and self.first_byte_s is None:
            self.first_byte_s = time.monotonic() - self.opened_at
        if not data:
            self.server_ended = True
            self.incoming.write_eof()
            return False
        self.incoming.write(data)
        return True

    def send(self, data: bytes) -> None:
        self.tls.write(data)
        self._flush()

    def fin(self) -> None:
        """TCP FIN without a TLS close_notify."""
        self.sock.shutdown(socket.SHUT_WR)

    def read_all(self) -> bytes:
        """Read plaintext until the server closes or READ_TIMEOUT_S passes with nothing."""
        out = b""
        while True:
            try:
                chunk = self.tls.read(65536)
                if not chunk:
                    return out
                out += chunk
            except ssl.SSLWantReadError:
                if not self._feed():
                    # one more read: the BIO may now hold buffered plaintext or EOF
                    try:
                        chunk = self.tls.read(65536)
                        out += chunk
                    except (ssl.SSLWantReadError, ssl.SSLZeroReturnError, ssl.SSLEOFError):
                        pass
                    return out
            except (ssl.SSLZeroReturnError, ssl.SSLEOFError):
                return out

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def request_head(method: str, path: str, key: str, content_length: int | None, close: bool) -> bytes:
    lines = [
        f"{method} {path} HTTP/1.1",
        f"Host: {HOST}",
        f"Authorization: Bearer {key}",
        "Accept: application/json",
    ]
    if content_length is not None:
        lines += ["Content-Type: application/json", f"Content-Length: {content_length}"]
    if close:
        lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode()


def dechunk(body: bytes) -> bytes:
    """Chunk sizes are hex lines; a truncated last chunk keeps what arrived."""
    out = b""
    rest = body
    while rest:
        size_line, sep, tail = rest.partition(b"\r\n")
        if not sep:
            break
        try:
            size = int(size_line.split(b";", 1)[0], 16)
        except ValueError:
            return body
        if size == 0:
            break
        out += tail[:size]
        rest = tail[size + 2 :]
    return out


def split_response(raw: bytes) -> tuple[str, str]:
    head, _, body = raw.partition(b"\r\n\r\n")
    status = head.split(b"\r\n", 1)[0].decode("latin-1") if head else ""
    if b"transfer-encoding: chunked" in head.lower():
        body = dechunk(body)
    return status, body.decode("utf-8", "replace")


def snippet(text: str) -> str:
    return " ".join(text.split())[:SNIPPET_CHARS]


def quota_snapshot() -> list[dict]:
    conn = TlsConn()
    try:
        conn.send(request_head("GET", QUOTA_PATH, api_key(), None, True))
        status, body = split_response(conn.read_all())
    finally:
        conn.close()
    if " 200" not in status:
        sys.exit(f"quota read failed: {status} {snippet(body)}")
    parsed = json.loads(body)
    return parsed["data"]["limits"]


def show_quota(label: str, limits: list[dict]) -> None:
    print(f"[usage {label}]")
    for item in limits:
        print("  ", json.dumps(item, ensure_ascii=False, sort_keys=True))


def chat_body() -> bytes:
    return json.dumps(
        {"model": MODEL, "messages": [{"role": "user", "content": "ok"}], "max_tokens": 8}
    ).encode()


def processed(status: str, body: str) -> bool:
    return " 200" in status or '"choices"' in body or '"usage"' in body


def control(key: str) -> bool:
    body = chat_body()
    conn = TlsConn()
    start = time.monotonic()
    try:
        conn.send(request_head("POST", CHAT_PATH, key, len(body), True) + body)
        status, resp = split_response(conn.read_all())
    finally:
        conn.close()
    has_usage = '"usage"' in resp
    print(f"[control] {status!r} after {time.monotonic() - start:.1f}s, usage in body: {has_usage}")
    if " 200" not in status:
        print(f"[control] body: {snippet(resp)}")
        return False
    return True


def status_code(status: str) -> int:
    parts = status.split()
    return int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0


def partial(key: str, label: str, sent_body_bytes: int) -> str:
    """One of: processed, refused, silent, unreadable.

    processed: the server answered the cut-off request as a complete one.
    refused: it answered with an error about the request itself (4xx other than 401/403/429).
    silent: it closed or timed out with no bytes.
    unreadable: 401, 403, 429 or 5xx, which says nothing about partial bodies."""
    body = chat_body()
    conn = TlsConn()
    start = time.monotonic()
    try:
        conn.send(request_head("POST", CHAT_PATH, key, len(body), False) + body[:sent_body_bytes])
        conn.fin()
        raw = conn.read_all()
    finally:
        conn.close()
    status, resp = split_response(raw)
    code = status_code(status)
    if processed(status, resp):
        outcome = "processed"
    elif not raw:
        outcome = "silent"
    elif code in (401, 403, 429) or code >= 500 or code == 0:
        outcome = "unreadable"
    else:
        outcome = "refused"
    print(
        f"[{label}] body {sent_body_bytes}/{len(body)} bytes sent, FIN, "
        f"response {len(raw)} bytes after {time.monotonic() - start:.1f}s, "
        f"status {status!r} -> {outcome}"
    )
    if resp:
        print(f"[{label}] body: {snippet(resp)}")
    return outcome


def control_fin() -> int:
    """The whole request, then a FIN. 200 means the silence of the partial
    requests is about their missing bytes; silence means it says nothing."""
    key = api_key()
    body = chat_body()
    conn = TlsConn()
    start = time.monotonic()
    try:
        conn.send(request_head("POST", CHAT_PATH, key, len(body), False) + body)
        conn.fin()
        raw = conn.read_all()
    finally:
        conn.close()
    status, resp = split_response(raw)
    has_usage = '"usage"' in resp
    print(
        f"[control-fin] whole body {len(body)}/{len(body)} bytes sent, FIN, "
        f"response {len(raw)} bytes after {time.monotonic() - start:.1f}s, "
        f"status {status!r}, usage in body: {has_usage}"
    )
    if resp:
        print(f"[control-fin] body: {snippet(resp)}")
    return 0 if " 200" in status else 1


def stall_case(key: str, label: str, sent_body_bytes: int) -> str:
    """Headers and the front of the body, then no FIN: the answer channel stays open.

    processed: 200 or a completion arrived.
    refused: an error about the request (for example 408 or 400).
    closed: the server ended the connection with no bytes before STALL_WAIT_S.
    waiting: nothing arrived for STALL_WAIT_S, so the server may simply wait longer.
    unreadable: 401, 403, 429 or 5xx."""
    body = chat_body()
    conn = TlsConn()
    conn.sock.settimeout(STALL_WAIT_S)
    start = time.monotonic()
    try:
        conn.send(request_head("POST", CHAT_PATH, key, len(body), False) + body[:sent_body_bytes])
        raw = conn.read_all()
        took_s = time.monotonic() - start
        ended = conn.server_ended
    finally:
        conn.close()
    status, resp = split_response(raw)
    code = status_code(status)
    if processed(status, resp):
        outcome = "processed"
    elif not raw:
        outcome = "closed" if ended else "waiting"
    elif code in (401, 403, 429) or code >= 500 or code == 0:
        outcome = "unreadable"
    else:
        outcome = "refused"
    print(
        f"[stall {label}] body {sent_body_bytes}/{len(body)} bytes sent, no FIN, "
        f"response {len(raw)} bytes after {took_s:.1f}s (server ended: {ended}, "
        f"reset: {conn.server_reset}, first byte at: {conn.first_byte_s}), "
        f"status {status!r} -> {outcome}"
    )
    if resp:
        print(f"[stall {label}] body: {snippet(resp)}")
    return outcome


def stall() -> int:
    key = api_key()
    n = len(chat_body())
    for label, sent in (("half", n // 2), ("all but last byte", n - 1)):
        outcome = stall_case(key, label, sent)
        if outcome in ("processed", "unreadable"):
            return 1 if outcome == "processed" else 3
        time.sleep(PAUSE_BETWEEN_S)
    return 0


def run() -> int:
    key = api_key()
    before = quota_snapshot()
    show_quota("before", before)
    if not control(key):
        print("control request failed: partial requests not sent, result would be unreadable")
        return 2
    after_control = quota_snapshot()
    show_quota("after control", after_control)
    n = len(chat_body())
    verdict = 0
    for label, sent in (
        ("headers only", 0),
        ("1 byte", 1),
        ("half", n // 2),
        ("all but last byte", n - 1),
    ):
        time.sleep(PAUSE_BETWEEN_S)
        outcome = partial(key, label, sent)
        if outcome == "processed":
            print(f"[{label}] the server treated a cut-off request as complete: stopping")
            verdict = 1
            break
        if outcome == "unreadable":
            print(f"[{label}] the answer says nothing about partial bodies: stopping")
            verdict = 3
            break
    time.sleep(PAUSE_BETWEEN_S)
    show_quota("after partial", quota_snapshot())
    return verdict


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("quota", "run", "control-fin", "stall", "control"):
        sys.exit(__doc__)
    if sys.argv[1] == "control-fin":
        return control_fin()
    if sys.argv[1] == "stall":
        return stall()
    if sys.argv[1] == "control":
        return 0 if control(api_key()) else 1
    if sys.argv[1] == "quota":
        show_quota("now", quota_snapshot())
        return 0
    return run()


if __name__ == "__main__":
    sys.exit(main())
