# Build-link Python helper: source-extraction probes

Captured on 2026-10-30 on Darwin 25.6.0 arm64 with OCaml 5.5.1 and Python
3.14.4. The input source was an uncommitted change on top of
`0ef0fdbb56423ae2e48828d981c5eea18cf90cf9`; the input file SHA-256 values
are in `summary.json`. The source-extracted test runner used `ocamlfind`,
`digestif.c` and `alcotest`; findlib warned that it found multiple digestif
interfaces.

`test-extract.py` compiles the actual request builder and four selected test
functions against simplified backend, exec and filesystem stubs; it also substitutes
`Digestif.SHA256` for `Agent_core_sha256`. It passed
the interpreter selection, collision, link validation and mkdir validation
cases. It does not run the repository's complete test executable, Eio process
transport, Apple Container or a Keeper guest.

`stdin-build-probe.py` extracts the shell wrapper and Python helper scripts
and runs them in a temporary host directory. It observed truncated, extra and
corrupt inputs rejected before link creation; preserved an existing
destination; and processed 4,400,000 bytes of synthetic stdin. It does not
measure guest performance or prove mounted-volume safety.

`summary.json` is a sanitized derivative: it omits host paths and full test
runner output, and records the SHA-256 of each original local receipt. Those
digests identify the original bytes, not the derivative. Both probes are
reproducible from the repository root into new output locations:

```sh
python3 docs/evidence/build-link-python-only-20261030/test-extract.py . \
  /tmp/masc-build-extract-new
python3 docs/evidence/build-link-python-only-20261030/stdin-build-probe.py \
  lib/keeper/keeper_sandbox_microvm.ml
```

No full Dune build, complete repository test, CI, installed MASC runtime or
Apple guest was exercised by these captures. The shell's `-x` test alone does
not show that an interpreter can execute in the target guest.
