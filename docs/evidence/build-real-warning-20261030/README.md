# Build-link warning and manual scan probes

Captured 2026-10-30 on Darwin arm64 with OCaml 5.5.1. The source was an
uncommitted change on top of `ebec2ac05d3aacbac89f19ca727d3891ef5dd25d`;
`summary.json` pins each source file's SHA-256. It is a sanitized derivative
of local output: the original-output digests identify those original bytes,
not the summary.

`extract-checks.py` generates two small OCaml programs from the actual plan,
warning, runtime logging branch and selected test. The first ran one Alcotest
case. The second ran four synthetic scan states against a stub logger. Neither
compiles the surrounding MASC module or exercises the actual Eio/provider path.

`manual-scan-check.py` extracts the English and Korean shell examples, verifies
that their executable text is identical and runs the example in a synthetic
host directory. It checks directory, file and symlink entries, keep-marker
states, search pruning, a symlink root refusal and fixture inode/content
preservation. The actual guest, Keeper uid/gid and concurrent writers were not
examined.

To reproduce from the repository root, use new output directories:

```sh
python3 docs/evidence/build-real-warning-20261030/extract-checks.py artifacts/build-warning-repro-new
ocamlfind ocamlc -package alcotest,astring -linkpkg \
  -o artifacts/build-warning-repro-new/warning_check artifacts/build-warning-repro-new/warning_check.ml
(cd artifacts/build-warning-repro-new && ./warning_check --color=never)
ocamlfind ocamlc -package astring -linkpkg \
  -o artifacts/build-warning-repro-new/runtime_warning_check artifacts/build-warning-repro-new/runtime_warning_check.ml
artifacts/build-warning-repro-new/runtime_warning_check
python3 docs/evidence/build-real-warning-20261030/manual-scan-check.py artifacts/build-warning-manual-repro-new
```

The fake-provider integration test, full repository build, CI, installed
runtime and real Apple guest remain separate and were not run here.
