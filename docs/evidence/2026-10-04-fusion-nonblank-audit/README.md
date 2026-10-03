# Nonblank Fusion conclusions: D5

Base: `deeef1dbf7ea16c1ed0759f7eefa34e182647215` (provider keys PR #41062).

A nonempty JSON object could contain empty resolved_answer and decision.answer
strings, pass the judge decoder, and terminate candidate selection as a success.
Required conclusion fields now use a nonblank string codec shared by the decoder
and output schema. The same rule applies to recommendation action/rationale and
to the explanatory resolved_answer of an insufficient decision. Accepted text
is preserved byte-for-byte. The external prompt explains this contract.

Whitespace means the documented OCaml String.trim set: space, tab, LF, CR and
form feed. The JSON schema character class expresses that same set. This is
field validation, not a keyword or answer-quality heuristic.

## Validation

Four changed OCaml files pass parser-only checks; git diff --check passes.
Three parser/schema cases are authored: fifteen blank-field scenarios, preserving
accepted text and explicit insufficient decisions, and output-schema constraints.
Two additional integration cases invoke real Fusion_judge.run, runtime lane
resolution and local Antigravity protocol subprocess fixtures: blank then valid
must select the second candidate; blank then blank must exhaust the lane. Both
assert actual child invocation, typed failed attempts and usage from both calls.

These native tests have not been executed. No typecheck, Dune build, CI, actual
provider request, live Keeper, installed binary, production or deployment claim.
No dashboard rendering change or browser screenshot is claimed.
