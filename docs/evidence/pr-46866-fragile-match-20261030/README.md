# PR #46866: extracted fragile-match checks

These records cover the two warning-4 matches reported on baseline commit
`b271cc4590b2841d0099f54851752955c94f9906`. The modified
`lib/keeper/keeper_turn_sandbox_runtime.ml` used in both runs has SHA-256
`d9feaf1bceea9ac40f2c27cf5d16abb4cc6a7acc4503696b0a5f58fe2390f707`.
The baseline runtime source has SHA-256
`cbfa1dc7caccb61c08bc3dd8db7e7e69d1e28a83206bb97802de3dc2195745a8`;
the unchanged CLI output source in both has SHA-256
`4c01c400c5e020b161b54a8943b9c8856e86d31cfcf0220039b99aa077482439`.
The target was a working-tree modification, not a committed head. The original
receipt also records the then-current tracked diff hash; it does not cover this
evidence bundle.

- `original-receipt.json` is the unmodified first capture, copied from
  `artifacts/fragile-match-review-20261030/receipt.json`; SHA-256
  `6b517cfc457f9d9efc497c274cf3403bc394004b901eeba43edbd44ceefe5fb8`.
- `portable-receipt.json` is the separate run of `reproduce.py`; SHA-256
  `5b3470df9d314f749eb74037afc12d1f12643ae9ec8ee4592562adf2e7a9128e`.
  It records OCaml 5.5.1 on Darwin arm64. Its extracted harness hashes and
  compiler/test outputs match the original capture. The two receipts have
  different metadata and are not the same byte sequence.
- `reproduce.py` SHA-256 is
  `74939b722748ee29eb3d2c238dec266dce159cf6820be58773ab13a1329423a0`.
  It was run against the baseline and working-tree source above with the
  command below; its temporary compiler products were not retained here.

The baseline extraction fails compilation with exactly two warning-4 errors.
The modified extraction compiles with warning 4 and warning 8 treated as
errors. It checks all eight capture error reasons, the three readiness states,
the limit-specific message, and that failed capture dispatches no effect in
the harness. Separately adding a synthetic new constructor to each type causes
warning 8 at the corresponding match.

The extracted runtime functions and CLI error definitions are actual source,
but the runner, logging, scan results, guest actions and other dependencies
are stubs. This is not a full MASC typecheck, fake-provider integration test,
CI result or live guest measurement. The four Keeper-requested tests were not
run locally; the independent Keeper reported that its earlier attempt could not
reach execution because the baseline compilation failed. This evidence does
not establish that those tests or the full project now build or pass.

To reproduce from the repository root, install Python 3.9 or newer, OCaml
5.5.1, `ocamlfind` and the `astring` package, and check out the target source
with the hash above. The baseline commit must be available locally. Choose a
new output path outside this retained bundle:

```sh
python3 -B docs/evidence/pr-46866-fragile-match-20261030/reproduce.py \
  --base-sha b271cc4590b2841d0099f54851752955c94f9906 \
  --expected-source-sha256 d9feaf1bceea9ac40f2c27cf5d16abb4cc6a7acc4503696b0a5f58fe2390f707 \
  --output artifacts/fragile-match-reproduction/receipt.json
```

The script rejects an existing output file, mismatched source hashes, changed
baseline/target CLI output definitions, and any unexpected compiler result.
It uses a freshly created temporary directory under the output directory and
removes only that directory, including its generated source and compiler
products. It does not call Dune, access a VM or operate a container service.
