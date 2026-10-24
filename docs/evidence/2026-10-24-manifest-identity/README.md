# Capability manifest identity admission (#27898)

Contradictory duplicate manifest rows previously selected `supports_tools = true`
or `false` depending only on declaration order. `before.json` records the actual
production parser and lookup at pre-fix base
`d587bf1ffa123a05ae688cbc9fabe8e35221b206`. The pinned reproduction reads that
commit with `git show` and compiles its four real modules and interfaces:

```sh
python3 docs/evidence/2026-10-24-manifest-identity/reproduce_before.py
python3 docs/evidence/2026-10-24-manifest-identity/run_fixture.py
```

The corrected boundary rejects identical and ASCII case-variant model identities,
including duplicates with identical facts, in either order. It uses the same
`Model_identifiers.Equality_key` as lookup. Distinct declarations remain usable,
original identity bytes remain visible, failed admission preserves the installed
manifest, and duplicate JSON keys remain rejected. Distinct overlapping prefixes
retain their existing selection order; this layer does not certify exact-model
catalog selection.

`Capability_manifest.t` is abstract. The actual compiled interface rejects both
raw-list installation and reinstallation of the read-only `entries` view. `empty`
is the explicit no-overrides value. No second registry is introduced.

`result.json` contains 14 checks, expected compiler rejections, and source/compiled
SHA-256 values. The runner compiles the actual `model_identifiers`,
`capability_vocab`, `reasoning_effort`, and `capability_manifest` modules and their
interfaces with `ocamlfind ocamlc -package yojson`. Only anchored inline-test
declarations are removed from module implementations; no dependency fixtures or
replacement implementation is used. The fixture runs actual manifest parsing,
lookup, and global installation. Requires OCaml, findlib, Yojson, Python, and Git.

This is standalone manifest-component evidence. The project, capability request
resolver, higher-level consumer suites, provider HTTP path, and installed runtime
were not built or executed. Changed consumer files received OCaml parser checks
and source review. The broader single-catalog, exact-model, and legacy-adapter
requirements of #27898 remain open.
