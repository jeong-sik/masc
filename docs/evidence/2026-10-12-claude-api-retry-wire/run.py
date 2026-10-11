import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
evidence = pathlib.Path(__file__).resolve().parent
capture = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else evidence / "captured-retries.jsonl"
source = root / "lib/runtime/runtime_claude_api_retry.ml"
template = (evidence / "verify.ml.in").read_text()
with tempfile.TemporaryDirectory(prefix="masc-retry-wire-") as temporary:
    harness = pathlib.Path(temporary) / "verify.ml"
    harness.write_text(template.replace("@SOURCE@", str(source)).replace("@CAPTURE@", str(capture)))
    result = subprocess.run(["ocaml", str(harness)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end="")
    sys.exit(result.returncode)
