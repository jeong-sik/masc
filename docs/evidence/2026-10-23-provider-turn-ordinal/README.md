# Authoritative provider-turn ordinal (#38066)

A resumed settled terminal returns an existing provider response without a new
AfterTurn hook. The pipeline already resolves its original ordinal. Advanced
success outcomes now retain that ordinal; Runtime stop reasons carry it through
to Keeper finalization. Runtime counts keep their original meanings. InputRequired
has no completed provider-turn witness. No missing ordinal is defaulted to zero.

The official adapters use the same ordinal as their completion hook. In particular,
Muse and Antigravity retain the frozen claim ordinal when context reconciliation
starts a new vendor session and resets the vendor count. Host stops accept that
ordinal separately from turns_used.

The saved-tool empty-terminal normalization requires an actual AfterTurn witness
from the same SDK invocation, a checkpoint, and a tool-result save from that
attempt. A replay with no new witness keeps its original typed error. This is
not a claim that every empty-terminal replay is repaired.

## Executed bounded checks

From the repository root, with OCaml 5.5.1 available:

```sh
python3 docs/evidence/2026-10-23-provider-turn-ordinal/verify_ordinal_ports.py \
  --output /tmp/masc-provider-ordinal-ports
```

The script extracts the actual Advanced loop/type declarations, Runtime
classification/projection, and Keeper normalization/answer predicate. It records
fragment line ranges and SHA-256 identities, the generated source, compiler argv,
exit status, and assertion output in the selected output directory. It fails if
compilation or execution fails. The original bounded run passed 18 assertions;
the extraction is repeated against the candidate rather than copying the functions.

Explicit ports replace Pipeline/frontier execution, leases, checkpoint construction,
logger/tracing, external types, and typed-empty ingress. The cases separate
nonzero ordinal from count, complete without a hook, retain the next resolved
frontier after Continue, preserve terminal/yield ordinals through Runtime, and
retain original errors when synthetic completion lacks evidence. These checks
do not run durable storage, providers, hooks, final metrics lookup, or ACK effects.

## Native regression sources (not executed here)

- `packages/agent_core/test/test_pipeline.ml`: original response/usage and ordinal 7
  survive a settled terminal replay; additional provider calls and AfterTurn hooks
  must both be zero, while restored count remains 8.
- `packages/agent_core/test/test_agent_advanced.ml`: completed, yielded and terminal
  tool results carry the resolved provider ordinal independently of count.
- `test/test_runtime_agent_execution_restart.ml`: the existing process-interruption
  fixture also checks the final ordinal after replaying a saved tool result and
  receiving the next provider response. This is a different crash window from
  the terminal replay above.
- Runtime classification, official host stops, synthetic evidence guards,
  InputRequired, and existing metric/receipt/ACK consumers were updated without
  relaxing their original assertions.

All changed OCaml sources were syntax parsed. Syntax parsing and port execution
are not whole-product typing, native test execution, CI, installation, or live
runtime verification. Those stages were not performed by this coding session.

## Independent source review

The review identified a P2 in Muse/Antigravity: using the reconciled vendor count
as the returned ordinal could disagree with the frozen completion-hook ordinal.
Both normal-completion and host-stop producers now use the frozen hook ordinal;
the vendor count is preserved. Independent review and GitHub approval are separate
stages; the PR records the current approval state.
