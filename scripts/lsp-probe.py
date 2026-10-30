#!/usr/bin/env python3
"""Ask a language server one question and report what it answered, and how fast.

Drives the server over stdio the way Lsp_workspace_pool does -- initialize,
didOpen, one request -- so a claim about what ocamllsp answers on this tree can
be re-checked rather than remembered.

    scripts/lsp-probe.py <workspace-root> <file> <line> <character> [question]

<line> and <character> are 0-based, as LSP counts them. [question] is one of
definition, hover, references (default: definition).

Written for issue #30504, which measured textDocument/references answering
same-file only on this repository.
"""

import json
import os
import subprocess
import sys
import time

QUESTIONS = {"definition", "hover", "references"}
# ocamllsp on a cold tree has answered in 2.2 s; a probe that gave up sooner
# would report "no answer" for a server that was still working.
ANSWER_TIMEOUT_SEC = 60


def main(argv):
    if len(argv) not in (5, 6):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root, target, line, char = argv[1], argv[2], int(argv[3]), int(argv[4])
    question = argv[5] if len(argv) == 6 else "definition"
    if question not in QUESTIONS:
        print(f"unknown question {question!r}; expected one of {sorted(QUESTIONS)}", file=sys.stderr)
        return 2

    server = subprocess.Popen(
        ["ocamllsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, cwd=root)

    def send(message):
        body = json.dumps(message).encode()
        server.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        server.stdin.flush()

    def read():
        length = 0
        while True:
            header = server.stdout.readline()
            if header in (b"\r\n", b"\n", b""):
                break
            if header.lower().startswith(b"content-length:"):
                length = int(header.split(b":")[1])
        return json.loads(server.stdout.read(length))

    def answer_to(request_id, deadline):
        while time.monotonic() < deadline:
            message = read()
            if message.get("id") == request_id:
                return message
        raise TimeoutError(f"no answer to request {request_id} in {ANSWER_TIMEOUT_SEC}s")

    try:
        started = time.monotonic()
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "rootUri": "file://" + root, "rootPath": root,
            "processId": os.getpid(), "capabilities": {}}})
        answer_to(1, started + ANSWER_TIMEOUT_SEC)
        print(f"initialize   {(time.monotonic() - started) * 1000:.0f} ms")
        send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

        uri = "file://" + target
        with open(target) as handle:
            text = handle.read()
        asked = time.monotonic()
        send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": uri, "languageId": "ocaml",
                             "version": 1, "text": text}}})
        params = {"textDocument": {"uri": uri},
                  "position": {"line": line, "character": char}}
        if question == "references":
            params["context"] = {"includeDeclaration": True}
        send({"jsonrpc": "2.0", "id": 2,
              "method": "textDocument/" + question, "params": params})
        reply = answer_to(2, asked + ANSWER_TIMEOUT_SEC)
        elapsed = (time.monotonic() - asked) * 1000
    finally:
        server.kill()

    result = reply.get("result")
    if result is None:
        shape = "null"
    elif isinstance(result, list):
        shape = f"{len(result)} items"
    else:
        shape = "object"
    print(f"{question:<12} {elapsed:.0f} ms  ->  {shape}")
    if isinstance(result, list):
        files = sorted({(item.get("uri") or item.get("targetUri", "?")).rsplit("/", 1)[-1]
                        for item in result})
        print("  " + "\n  ".join(files))
    elif isinstance(result, dict):
        print("  " + json.dumps(result)[:400])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
