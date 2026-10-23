# Shared candidate standing: issue #38061

The original provider-529/local-admission confusion was already repaired before
this change. The remaining defect was that CLI and Vision ordered candidates by
account quota alone while the Keeper walk and HTTP Exact also read candidate
rate evidence. Vision recorded only HTTP 402, and a CLI dispatch observer could
rebind a runtime ID between admission and the default runner's second lookup.

`Runtime_candidate_standing` reads frozen candidate and quota projections once.
It preserves every declared candidate and stable ordering inside each class.
Keeper walks retain their existing three classes and fresh-recorder exception.
Ownerless Exact/CLI/media calls retain the existing provider path-rest policy
and ignore Fleet failed-attempt marks; they do not create a recorder or a new
expiry/configuration policy.

HTTP and official-client observations belong to the actual captured runtime.
429 is candidate-only; 402, typed hard quota and official-client spent usage
belong to the captured account scope. A real answer clears candidate evidence
and undated quota before final callbacks or JSON/domain validation, while a
provider-stated reset survives. HTTP Exact preserves the SDK's 402 body/header
hint and records dispatched typed hard quota; a failure before generation
dispatch does not become provider evidence. Admission/fallback/dispatch rules
otherwise remain owned by their existing callers.

## Executed evidence

Run the bounded check with the repository OCaml/opam toolchain installed:

```sh
python3 docs/evidence/2026-10-23-candidate-standing/reproduce.py .
```

It copies the complete current ML/MLI of Standing, Quota, Backpressure and its
State into a named artifact namespace, compiles with warnings 4/32/69 fatal,
and executes nine cases. Source bodies are not rewritten. The adjacent manifest
binds the exact eight source files and harness bytes; compile/run logs preserve
the invocation and outcome.

The explicit boundary ports replace credential/home/SDK identities and hint
validation. HTTP classification and body/header parsing deliberately fail if
called. Test rest callbacks supply their own duration. Thus these nine cases
prove the algorithms for declared inputs, including ordering, shared quota vs
candidate-only rate, success clearing and ownerless failure neutrality. They
do **not** prove the real SDK parsers, account-home resolution, production rest
calculation, registry identity preservation, adapter dispatch or the wrappers.

Before the shared checkout's existing `_build` cache disappeared, selected
Standing/Fusion/CLI source and an earlier CLI test revision compiled against
cached dependency interfaces. That cache was not authenticated as a complete
current dependency build. The CLI test gained another regression afterward;
the SDK hint repair and final HTTP Exact delta came later. Those historical
compile results are not final integrated typecheck or execution evidence.

## Native regressions and review

Existing suites now cover CLI and Vision shared rate ordering, subsequent calls,
actual-adapter success before malformed JSON rejection, typed account/rate
distinction, and dispatch/in-flight rebind isolation. HTTP Exact adds loopback
payment/reset and semantic-rejection cases; SDK flow tests cover 402 body/header
hint precedence. A typed Exact-cause fixture reuses actual flow receipts and
replaces only the cause, so it does not claim the HTTP fixture emitted a typed
hard-quota transport error.

These native integration regressions were authored and syntax-checked but were
**not executed** by this external coding session. Final changed-source syntax
and whitespace checks are recorded separately. Independent agent source review
and MASC current-head GitHub review are separate from these checks.

No local Dune build, full source typecheck, CI dispatch, installed binary,
real-provider call, runtime restart or live Keeper result is claimed.
