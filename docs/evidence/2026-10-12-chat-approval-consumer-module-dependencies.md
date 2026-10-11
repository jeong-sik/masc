# Approval consumer dependency and ownership-check repair

Base: `a8520037683f3a4d723fb942de78f6295bf82b28`.

Independent source reviews of `c5e87c5d8aab0fa90d1205a4ac4aa5e00f62f804` found two P2 compile-boundary defects: the authority Dune library directly uses Masc without declaring its direct dependency; the actor-log test references the wrapped admission module without qualification. A separate review-response agent confirmed both findings. Original HOLD findings remain historical at the reviewed head.

The authority stanza now declares `masc`; the actor-log fixture explicitly uses `Masc.Keeper_tool_approval_id` for both conversions and generation. Review also found weakened test scope: deriving an unknown ID when the wrong Keeper or expired wait was absent stopped checking the original admission. Those two tests now retain the actual admitted ID and submit it with the wrong Keeper or after timeout.

Validation: `git diff --check` passed. OCaml 5.5.1 syntax-only parsing of the two changed test files passed without diagnostics. Source inspection confirms the exact authority stanza dependency and fully qualified test module. No local Dune build or OCaml typecheck/function execution was performed; dependency correctness awaits corrected cumulative independent source review. The preceding replay feature checks passed 166 Web tests and noEmit at its own source scope, not as proof of this OCaml repair.

Review artifacts: `/tmp/masc-approval-admission-authority-independent-review-20261012/review.json`, `/tmp/masc-approval-ocaml-dependency-response-review-20261012/report.md`. No formal approval/merge/runtime/screenshots claim. Home/Agenda and chat receipt ownership plus broader provider/runtime/streaming goal remain incomplete.
