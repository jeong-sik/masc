"""Run the complete production handoff with installed Eio, without Dune."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
source = root / "lib/server/server_keeper_stream_handoff.ml"
template = pathlib.Path(__file__).with_name("repro.ml.in").read_text()
with tempfile.TemporaryDirectory(prefix="masc-handoff-eio-") as temporary:
    harness = pathlib.Path(temporary) / "repro.ml"
    harness.write_text(template.replace("@SOURCE@", str(source)))
    result = subprocess.run(["ocaml", str(harness)], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    sys.exit(result.returncode)
