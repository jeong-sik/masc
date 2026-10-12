# Autonomous marker source authority

Base: `4f7b4e65f03f36adfc9f7018b1f78cb201d5d41b`.

The assistant history branch previously treated any autonomous_turn object as
proof of autonomous execution. This could suppress empty original speech even
when the marker lacked a valid turn reference or contradicted a canonical
Operation owner. Classification now requires the parsed marker turn reference
to equal the observed Autonomous_turn execution source. Unmarked direct trace
rows remain direct. Original body bytes are retained.

## Bounded evidence

Artifacts: `/tmp/masc-tui-autonomous-marker-source-20261012/`.
The current harness runs the unchanged production decision helper. It supplies
minimal source types, a marker accessor stub and a two-reference parser stub.
The parent harness models the previous object-presence decision using optional
marker presence; it does not execute the previous JSON object match.

Parent modeled decision exits 1; current decision exits 0 across missing,
invalid, direct Operation, conflicting autonomous and matching autonomous cases.
This establishes the source decision difference, not production JSON decoding.

Two changed OCaml files passed syntax-only parsing; diff whitespace check passed.
The registered canonical wire state fixture is unexecuted. Full typecheck,
full history ingestion, rendering, runtime, screenshots, CI, approval and merge
are unverified. Unknown speech classification is unchanged; this does not
establish terminal authority for root replies or unknown sources.
