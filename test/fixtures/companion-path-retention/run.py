#!/usr/bin/env python3
"""Execute actual cleanup functions with explicit Eio ports and real Unix sockets.

This component probe does not execute the full Eio broker/runtime lifecycle.
"""
from pathlib import Path
import hashlib
import subprocess
import tempfile

FIXTURE = Path(__file__).resolve().parent
ROOT = FIXTURE.parents[2]


def execute(name, source):
    with tempfile.TemporaryDirectory(prefix="companion-retention-probe-") as directory:
        probe = Path(directory) / "probe.ml"
        probe.write_text((FIXTURE / (name + "-ports.ml")).read_text() +
                         source + (FIXTURE / (name + "-scenarios.ml")).read_text())
        subprocess.run(["ocaml", "-I", "+unix", str(probe)], check=True)


broker = (ROOT / "lib/lane_addon/lane_addon_companion_broker.ml").read_text()
listener = broker[broker.index("let private_listener "):broker.index("let create ~sw ~directory")]
execute("listener", listener)
print("listener source sha256:", hashlib.sha256(listener.encode()).hexdigest())

allocation = (ROOT / "lib/lane_addon/lane_addon_companion_allocation.ml").read_text()
start = allocation.index("      let cleanup = Eio.Lazy.from_fun")
end = allocation.index("      startup_cleanup := Some cleanup;", start)
closure = allocation[start:end]
execute("allocation", "let make_cleanup ~original ~releasing ~settlements ~directory =\n" +
        closure + "cleanup\n")
print("allocation cleanup source sha256:", hashlib.sha256(closure.encode()).hexdigest())
