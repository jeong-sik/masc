# Production SSE framing measurement

The unchanged complete `lib/sse_wire/sse_wire.ml` was interpreted with OCaml 5.5.1 and installed Yojson, followed by `scripts/benchmarks/chat-sse-framing/probe.ml`. No production dependency was stubbed. `result.json` records both input hashes and actual execution output.

929 protocol checks passed over six synthetic payloads: observed thinking text, original Unicode saying text, opaque tool argument text, external payload, id-less acceptance, and multiline/trailing-newline body. Every two-chunk byte cut was exercised for LF and CRLF; byte-at-a-time delivery also split UTF-8 and BOM bytes. Other cases cover fresh-decoder reconnect isolation, explicit frame-local IDs, invalid NUL IDs, whitespace lines, and unterminated EOF.

Reproduce from the repository root (no Dune build):

```sh
python3 - <<'PY'
from pathlib import Path
import subprocess, tempfile
source = Path('lib/sse_wire/sse_wire.ml').read_text()
probe = Path('scripts/benchmarks/chat-sse-framing/probe.ml').read_text()
with tempfile.TemporaryDirectory(prefix='masc-sse-framing-') as directory:
    loader = Path(directory) / 'run.ml'
    loader.write_text('module Sse_wire = struct\n' + source + '\nend;;\n' + probe)
    library = subprocess.check_output(['ocamlfind', 'query', 'yojson'], text=True).strip()
    result = subprocess.run(['ocaml', '-I', library, 'yojson.cma', str(loader)])
    raise SystemExit(result.returncode)
PY
```

This is framing evidence, not full SSE semantic decoding or live provider parity. Synthetic event objects are opaque framing inputs and are not asserted to satisfy their respective event schemas. The actual Live decoder, journal/state reducers, HTTP disconnect handling, Keeper execution, operator input incorporation, installation and terminal rendering were not exercised. No screenshot or hidden reasoning is inferred from this result. No production change was needed for the measured cases.
