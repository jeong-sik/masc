# L3: cleanup diagnostics must preserve the selected exception

The canonical execution runner already chooses which exception to propagate
when abort or terminal-receipt cleanup fails. Its two reporting sites then call
`Eio.traceln` before rethrowing that exception. A failed debug output channel
could therefore replace `Sys.Break` or cancellation with `Sys_error`.
These sites are outside the inner `Tracing.with_span` operation boundary.

L3 uses one private `report_cleanup_failure` function at both sites. It isolates
ordinary diagnostic failures and delegates new runtime/control failures to the
existing `Llm_provider.Reserved_exn` policy. It changes neither canonical abort
and terminal settlement nor the separate HostStop judgment. A host stop requires
all contained reasons to be host stops; Reserved requires any contained reserved
cause. No diagnostic counter, retry, rate limit, or new public API is added.

## Actual source replay

[results.json](results.json) is a selected derivative of the original capture at
`artifacts/runner-cleanup-diagnostic-20261116/private-channel-proof-with-provenance`.
It retains the original capture digest, source/helper hashes, L1 Reserved source
hash, OCaml version, and installed Eio core/main bytecode hashes. The installed
Eio package does not declare a version in its findlib metadata. Only the OCaml
executable's absolute installation path was reduced to its basename.

The replay uses the actual extracted production cleanup helper and actual
installed Eio, with the same L1 Reserved implementation for both candidates:

- Before: helper from `e11f6e704d10dbe2bff12fcbbbf966bb28c589d4`.
- After: uncommitted runner source over checkout
  `00b8d1b5dd0afca229511711f44bbd76cb79543b`, identified by its recorded hashes.
- Healthy debug binding: all three primary exceptions retain object identity.
- Debug binding writing to a closed **private duplicate of stderr**: before
  loses the original for `Sys.Break`, cancellation, and a mixed reserved
  aggregate; after preserves each original despite the real channel IO failure.
- New logger OOM, cancellation, and a mixed reserved aggregate propagate intact
  before and after. The repair does not swallow these controls.

Both sides matched those expected observations, nine cases each. The before
match records the reproduced bug, not a successful repair. The earlier capture
at `artifacts/runner-cleanup-diagnostic-20261116/private-channel-proof` remains
unchanged. Capture-time hashes identify those exact bytes; they do not certify
a later restacked whole file or commit.

To create a new, separately owned run from the candidate checkout:

```sh
python3 docs/evidence/runner-cleanup-diagnostic-20261116/reproduce.py \
  --out artifacts/runner-cleanup-diagnostic-20261116/new-run
```

This requires an OCaml interpreter, findlib's `topfind`, installed `eio_main`,
and the recorded before commit. It writes new output without overwriting prior
captures. It invokes no Dune command or model provider and does not close process
stderr or redirect `Format.err_formatter`.

## Public consumer regression source and limits

[test_agent_cleanup_diagnostics.ml](../../../packages/agent_core/test/test_agent_cleanup_diagnostics.ml)
uses real `Agent.execution_store` and `Agent.run`. Its scope-publication callback
raises the primary exception before any provider call. The canonical journal
settles that failure; the terminal receipt sink then either returns an error or
raises a reserved exception, reaching the two cleanup-reporting sites.

Four registered cases assert the original exception identity and source location
under real private-channel failure, new reserved logger propagation, zero
provider calls, one publication/receipt invocation, and the unchanged canonical
failed/cancelled terminal with its recovery disposition. The process's stderr
and Alcotest formatter remain available throughout the assertions.

Those public-path regressions were written and parsed, **not executed**. The
source replay executes only the extracted helper, not `Agent.run`, the execution
writer, both full cleanup branches, or journal persistence. No SDK typecheck,
Dune build, Alcotest suite, CI, native provider, or live Keeper was run for L3.
Existing L1/L2 captures and any separately running verifier are outside this
bundle's execution scope.
