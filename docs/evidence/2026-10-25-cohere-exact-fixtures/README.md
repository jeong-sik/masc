# Cohere exact declaration parser evidence

This reproducer reads the selected repository's real source objects and runs
the existing Cohere fixture helpers against the actual production parsers.
It writes sources and compilation products only inside an owned temporary
directory, which is removed on exit. It does not use Dune, dispatch CI, change
branches or modify an existing worktree. No full production module copies or
compilation products are included in this evidence directory.

The probe's author assembled this runner. Its output is component execution
evidence, not independent approval of either PR layer.

## Run once

Use Python 3.11 or newer, Git, OCaml 5.5.1 and `ocamlfind`, with these installed
packages: `yojson`, `otoml`, `ppx_deriving.show`, `ppx_deriving.eq`, and
`ppx_deriving_yojson.runtime`. The receipt records the versions actually used.
The selected checkout must already contain the requested commits and source
objects; a missing object is an error. No dependency installation is performed.

From this evidence directory inside the checkout:

```sh
python3 run.py --before-ref 0ccb01b6ac91e47950fd3e74bdf9c38c95aefa92 --after-ref cee9238b935ad1b019232627256e0efac64b36f7
```

The repository is resolved with `git rev-parse --show-toplevel` from the current
directory. Use `--repo PATH` to select a different checkout explicitly. Both
refs are resolved to commits in that same repository before any source is read.
The command prints its complete JSON receipt to stdout. Optional
`--receipt receipt.json` creates that new file and prints the observed probe
output instead; an existing receipt file is refused. It is the only optional
write outside the temporary directory.

## What executes

`run.py` reads the after-ref's nine production ML/MLI pairs:
Reasoning_effort, Model_identifiers, Serving_constraint, Provider_kind,
Capability_vocab, Model_provider_catalog, Serving_constraint_catalog,
Capability_manifest and Model_catalog. It generates Model_catalog_embedded
from the exact after-ref `models.toml` bytes. These 19 production inputs are
identified by source path, Git blob and SHA-256 in the receipt.

`prepare_parser.ml` uses the OCaml compiler AST to exclude inline-test
extensions from those modules. Their product declarations and function bodies
remain; actual interfaces are compiled. No parser, vocabulary or lookup behavior
is stubbed. The same utility extracts the existing `catalog`, `manifest` and
`provider` helper bindings from the before/after complete Cohere test files.
`probe.ml` invokes those actual helpers and parsers, without hand-translating
the fixture data.

The 14 observed probes comprise:

- Four original-helper rejections: two valid dialects in TOML and JSON. The
  original TOML lacks `model_id`; the original manifest uses schema1.
- Four successful corrected typed rows: both dialects in each format retain
  the original model identity.
- Four unknown/empty dialect rejections at the actual dialect validators.
- Successful parsing of the actual embedded default catalog.
- A check that the separate provider helper retains schema1.

The provider helper check inspects its data. It does not execute
Provider_catalog's runtime parser. The existing production provider parser's
schema contract is unchanged by the repair.

## Scope of the recorded result

`observed-result.json` records one actual runner invocation against before
`0ccb01b6ac91e47950fd3e74bdf9c38c95aefa92` and after
`cee9238b935ad1b019232627256e0efac64b36f7`; `observed-output.txt` preserves that
invocation's stdout. The production-input hashes and reused support-file hashes
are retained. Successful original rejection probes describe the reproduced
failure, not successful execution of the old Cohere regression suite.

The earlier three-value fixture-only repair still passed the removed `~io`
argument to `Exact_output.load_resolver_snapshot`. That separate source finding
invalidated its earlier full source PASS. The current lower candidate also
removes the obsolete argument. Consequently the before/after exact-frozen
test-function ASTs differ; the receipt records that fact and both hashes.
AST comparison is not an interface/type compatibility check.

**The whole Cohere test executable and Exact_output snapshot, admission,
fingerprint and HTTP paths are unexecuted.** This component does not establish
whole-project typecheck/build, full regression, Dune/CI success, installation,
runtime behavior or formal approval. A successful parser probe cannot hide a
failure in an uncompiled consumer.
