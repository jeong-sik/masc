"""Parse the changed source with OCaml 5.5.1; no type/link/runtime claim."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
out = root / "docs/evidence/2026-10-04-curator-activity-resume"
configured_bin = os.environ.get("CURATOR_OCAML_BIN")
if configured_bin:
    compiler = Path(configured_bin) / "ocamlc"
else:
    found = shutil.which("ocamlc")
    if found is None:
        raise RuntimeError("Set CURATOR_OCAML_BIN to an OCaml 5.5.1 bin directory")
    compiler = Path(found)
version = subprocess.check_output([str(compiler), "-version"], text=True).strip()
if version != "5.5.1":
    raise RuntimeError("Expected OCaml 5.5.1, got " + version)
sources = [
    "lib/runtime/runtime_exact_output_registry.ml",
    "lib/runtime/runtime_exact_output_registry.mli",
    "lib/server/server_workspace_memory_curator.ml",
    "lib/server/server_workspace_memory_curator.mli",
    "test/test_exact_output_catalog_precedence.ml",
    "test/test_exact_output_catalog_precedence_fixture.ml",
    "test/test_workspace_memory_curator_lane.ml",
]
results = []
for source in sources:
    command = [str(compiler), "-stop-after", "parsing", "-c", source]
    result = subprocess.run(command, capture_output=True, text=True)
    results.append({"path": source, "sha256": hashlib.sha256((root / source).read_bytes()).hexdigest(),
                    "returncode": result.returncode, "output": result.stdout + result.stderr})
(out / "parser.json").write_text(json.dumps({"compiler": version,
    "scope": "Syntax only; no Dune, full typecheck, linking or execution", "files": results}, indent=2) + "\n")
if any(result["returncode"] for result in results):
    raise RuntimeError("Source parsing failed; see parser.json")
print(f"PASS: {len(results)} OCaml source files parsed")
