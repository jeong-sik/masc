#!/usr/bin/env python3
"""Compile the actual tick module/tests with two production type declarations.

No main/HTTP/server implementation is substituted or claimed as linked.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BIN = Path(os.environ.get("MSX_TICK_OCAML_BIN", "/Users/dancer/.opam/5.5.1/bin"))
ENV = dict(os.environ, PATH=str(BIN) + os.pathsep + os.environ.get("PATH", ""))
FILES = [
    "bin/masc_tui_msx_tick.mli", "bin/masc_tui_msx_tick.ml",
    "test/test_tui_msx_tick.ml",
]
PARSE = FILES + [
    "bin/masc_tui_async_protocol.mli", "bin/masc_tui_async_protocol.ml",
    "bin/masc_tui_http.ml", "bin/masc_tui.ml",
    "lib/server/server_routes_http_routes_msx.mli",
    "lib/server/server_routes_http_routes_msx.ml", "test/test_msx_routes.ml",
]
sha = lambda data: hashlib.sha256(data).hexdigest()
work = Path(tempfile.mkdtemp(prefix="masc-msx-tick-551-"))
commands = []
sources = {}
logs = []


def run(command):
    process = subprocess.run(command, cwd=work, env=ENV, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    commands.append({"argv": command, "exit_code": process.returncode})
    logs.append("$ " + " ".join(command) + "\n" + process.stdout.rstrip() + "\n")
    (OUT / "leaf.txt").write_text("\n".join(logs))
    if process.returncode:
        raise SystemExit(process.returncode)
    return process.stdout.strip()


version = run([str(BIN / "ocamlc"), "-version"])
if version != "5.5.1":
    raise SystemExit("Expected OCaml 5.5.1, got " + version)
for source in FILES:
    data = (ROOT / source).read_bytes()
    sources[source] = sha(data)
    shutil.copyfile(ROOT / source, work / Path(source).name)
for source, start, end in [
    ("bin/masc_tui_types.ml", "type msx_meta =", "(* A container-log read"),
    ("bin/masc_tui_machine_live.ml", "type mark =", "type time ="),
]:
    text = (ROOT / source).read_text()
    begin = text.index(start)
    fragment = text[begin:text.index(end, begin)]
    (work / Path(source).name).write_text(fragment)
    sources[source] = {"whole_source_sha256": sha(text.encode()),
                       "extracted_sha256": sha(fragment.encode()),
                       "start": start, "end": end}
compiler = [str(BIN / "ocamlfind"), "ocamlc", "-thread", "-package", "yojson,base64,eio,alcotest"]
for source in ["masc_tui_types.ml", "masc_tui_machine_live.ml",
               "masc_tui_msx_tick.mli", "masc_tui_msx_tick.ml", "test_tui_msx_tick.ml"]:
    run(compiler + ["-c", source])
run(compiler + ["-linkpkg", "masc_tui_types.cmo", "masc_tui_machine_live.cmo",
                "masc_tui_msx_tick.cmo", "test_tui_msx_tick.cmo", "-o", "test.exe"])
run([str(work / "test.exe"), "--color=never"])
(OUT / "leaf.json").write_text(json.dumps({
    "scope": "Actual complete tick module and six tests with extracted production frame/mark type declarations. Not full TUI/HTTP/server link.",
    "compiler": version, "temporary_directory": str(work),
    "sources": sources, "commands": commands,
}, indent=2) + "\n")
syntax = []
for source in PARSE:
    command = [str(BIN / "ocamlc"), "-stop-after", "parsing", "-c",
               "-intf" if source.endswith(".mli") else "-impl", str(ROOT / source)]
    process = subprocess.run(command, cwd=work, env=ENV, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    syntax.append({"source": source, "sha256": sha((ROOT / source).read_bytes()),
                   "argv": command, "exit_code": process.returncode,
                   "output": process.stdout})
(OUT / "syntax.json").write_text(json.dumps({"compiler": version, "checks": syntax}, indent=2) + "\n")
if any(check["exit_code"] for check in syntax):
    raise SystemExit("Syntax check failed")
print("OCaml " + version + ": actual tick leaf 6/6; syntax 10/10; output " + str(OUT))
