# Memory transition evidence experiment — 2026-10-08

Question: does the forward consolidation judge reject a valid event continuation
because its input lacks the new observation that supports the changed state?
This experiment changes no production behavior. It uses synthetic incidents only.

## Frozen comparison

`policy.json` records the source head, source digest, model alias, and complete
questions. `cases.json` contains six scenarios and the expected merge admission.
`results.json` retains all 54 answers, typed probabilities, provider-reported model,
usage, request digests, and errors if any. Credentials are never recorded.

| Arm | Input | Intended decisions matched |
|---|---|---:|
| pair_only | Production question, old memory and candidate | 15/18 |
| instruction_only | Evidence-aware question, observations explicitly empty | 12/18 |
| with_evidence | Same evidence-aware question, supplied observations | 18/18 |

Each arm has six cases repeated three times. Evidence-aware means the exact suffix
in policy.json: distinguish observed events from plans, check event identity, and
compare the candidate with both the old memory and observations. The instruction
control isolates evidence content from this question change, although an empty
observations list is itself a meaningful absence cue.

The original stale-lock continuation was rejected on all three pair-only calls
and accepted on all three evidence calls. The TLS continuation was accepted by
pair-only, rejected by instruction-only, and accepted with evidence. Four negative
cases (another incident, planned outcome, lost condition, contradictory observation)
were rejected across all arms. No call failed. These are 54 evaluations of six
cases, not 54 independent scenarios; model repetitions do not establish statistical
independence or calibrated confidence. The controls were run after the first two
arms, not randomized. The alias resolved to the model recorded in each response.

The six scenarios are a small development set, partly based on known refusals.
This is not a held-out benchmark or evidence of installed Keeper behavior. A judge
can preserve or reject a pair without establishing the truth of new observations.
The result supports implementing a source-backed evidence input, not claiming
that all event transitions now consolidate correctly.

## Reproduce

Dry-run renders exactly the frozen requests without network access:

```sh
python3 experiments/memory-transition-evidence/run.py --output /tmp/memory-requests.json
```

To make paid calls, supply the existing `TYPESAFEAI_API_KEY` securely and run:

```sh
python3 experiments/memory-transition-evidence/run.py --execute --output /tmp/memory-results.json
```

The frozen question is deliberate: changing current production source does not
silently change this experiment. Export a new policy and record its source identity
for a new comparison. The script reads only its adjacent synthetic files, never
`.masc`; the transport deadline limits one HTTP request, not Keeper behavior.

## Next production slice

Pass the Librarian's actual source observations and their identity into forward
judgment, with the old memory and candidate. Preserve provider-size handling,
pre-dispatch persistence, cancellation and unknown-outcome behavior. Do not let a
model-generated summary masquerade as observed completion. Prove that the runtime
passes the original evidence, then replay the changed gate and measure resulting
current-memory commits and next-turn context separately.

Related: #41907, #41910. The earlier targeted run 37772617048 passed all 240 tests
on 4fee263c15c069c5a12072023709d63f7784305f. It covers the existing stack's gates,
cancellation, maintenance, shared view, prompt renderer and tool dispatch. It does
not execute this experiment or the not-yet-implemented evidence input.
