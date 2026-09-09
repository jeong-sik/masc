# First installed runtime sample

Executed the installed `masc runtime-token-sample` with the repository's four-turn
example and existing deployment configuration. Exact binary identity, scenario
hash and runtime config revision are in `sample.jsonl`; its unchanged bytes are
hashed in `summary.json`. No credential or runtime configuration file is included.

GLM completed all four turns: Lantern, violet, updated amber, and the prior violet
value were retained in the visible answers. Reported totals: input 434, output 247,
cache-read input 128. These normalized counts are observations, not savings.

Kimi failed before its first response because the deployment overlay declares
reasoning support but no thinking-control format while the resolved request
requires thinking disabled. Usage is unknown, not zero. The failure appears in
the original log. This is a config/capability mismatch, not evidence of an API
outage or provider inability. No runtime settings were changed to hide it.

Remaining: correct the deployment's capability declaration against the actual
provider contract, repeat Kimi, then run representative ten-turn and before/after
scenarios. This small smoke alone does not complete the optimization acceptance.
