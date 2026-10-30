# Queue inventory observation validation

Implementation: `c7b705e02bce015ba9c44f1b8de111dff00b160e`, based on `a3461f1fb69fc85041ab62ae0d27a60902c1c90d`.

The eight files listed in `results.json` passed individual OCaml 5.5.1 type
checks, with warnings 8, 32 and 69 treated as errors. `typecheck.log` summarizes
the observed exit codes; the individual logs preserve compiler output (empty
on successful checks). Source hashes identify the checked files and the other
files changed by the implementation.

Each invocation used `ocamlc -w +8+32+69 -warn-error +8+32+69 -c -o <scratch-output>`
with include directories for the existing shared-checkout compiled interfaces
and installed 5.5.1 switch. Parent-library sources used `-open Masc`. Interfaces
were compiled into the scratch directory before their implementations. The
existing test dependency helper was also compiled there so the observer test
could be typechecked. No shared build artifacts or OPAM switch were changed.

These checks reused cached dependency interfaces. They do not prove a complete
candidate build or runtime compatibility of the dependency graph. The Dune
change explicitly declares the new schedule and type-library dependencies;
Dune itself was not run.

Behavioral tests were added for mixed queue counts, schedule lifecycle,
unrecognized input, admission ambiguity, and live execution after lifecycle
changes. **Those tests were typechecked, not executed. No candidate PTY,
screenshot, provider invocation or production behavior was verified.**

The server inventory remains inclusive of future reservations. The TUI
separates their lifecycle and counts without changing runtime admission.
Pending event identity alone does not establish admission to the current turn;
payload-kind matching is not used to infer it. Parallel execution spaces and
external-effect cancellation remain outside this change.
