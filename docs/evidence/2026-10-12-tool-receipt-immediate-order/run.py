"""Execute the production receipt module with explicit external dependency doubles."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve(strict=True)
template = Path(__file__).with_name("repro.ml.in").read_text()
with tempfile.TemporaryDirectory(prefix="receipt-release-") as directory:
    harness = Path(directory) / "repro.ml"
    harness.write_text(template.replace("__SOURCE_FILE__", json.dumps(str(source))))
    result = subprocess.run(["ocaml", str(harness)], check=False)
sys.exit(result.returncode)
