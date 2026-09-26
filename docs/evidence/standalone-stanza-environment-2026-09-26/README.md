# Standalone suite environment

Focused candidate CI `36241261804` passed seven active frame-timing cases via
the targeted runner, which reads the Dune stanza environment. Its optional
standalone step failed the same suite's `stanza enables real recording path`
assertion because it omitted that environment. The workflow remained green
because the standalone step uses `continue-on-error`.

The standalone runner now uses the existing `scripts/ci/stanza_env.py` reader.
It reads the checkout containing the compiled test, including literal shared
includes, applies directory values followed by nested action overrides, and
preserves empty values. `--source-root` continues to select only the checkout
inspected by assertions through `DUNE_SOURCEROOT`.

Environment values requiring a Dune action dependency are unsupported in the
standalone staging directory. They and unresolvable variables produce an
environment error before staging, compilation or execution. A dedicated
`SuiteEnvironmentError` makes the CLI exit nonzero and report that the suite
was not run, separately from an executed test failure. It is not counted as a
nonfatal unbuilt suite. The shared reader's
default dependency support is unchanged for the targeted Dune runner.

## Discriminating local evidence

`baseline.txt` and `candidate.txt` run the same scenario with the original main
`1c717324a5e505b5088e0f8b8cf671ebf430d17f` runner and changed runner respectively.
A real Python child records its received environment. It checks directory
clearing, nested override precedence, a value containing spaces, no leakage
from a neighboring included test, and an independent inspected source root.
The baseline fails the environment assertion and the changed runner passes.
`identity.json` records both source hashes and the scenario source hash.

OCaml staging and compilation are stubbed in this scenario. It proves actual
child environment propagation, not a compiled OCaml timing test. The full local
Python suite has 24 passing cases and one explicitly skipped CI-only compile
fixture. Shared stanza-reader self-tests pass. Reading the real frame-timing
stanza in the feature checkout resolves its declared timing report path and
empty `MASC_BASE_PATH`. No local OCaml build was run.

Independent adversarial review found no source defect. Compiled CI and the
standalone run of the instrumented timing suite still need confirmation.
