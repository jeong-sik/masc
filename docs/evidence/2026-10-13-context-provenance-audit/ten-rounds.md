# Ten additional audit rounds

Requested after the initial fixes in PRs #42713, #42716 and #42718.
Starting code: `d349d5853588292f0b0bbdcb6c2c10d8262bbbe2`.
The scope is context/reasoning provenance across provider and Keeper boundaries.
Each round records its invariant, counterexample, source/test evidence, changes,
independent review and remaining execution limits. A source inspection is not a
live-runtime or live-provider pass. Previously completed work is not counted as
one of these ten rounds.

| Round | Boundary | State |
|---|---|---|
| 1 | Malformed context provenance in Librarian evidence | Repair implemented; independent review and behavior execution pending |
| 2 | Suppressed terminal replies and retained context ownership | Pending |
| 3 | Streamed response provenance and checkpoint collection | Pending |
| 4 | Hook or persistence failure after provider response | Pending |
| 5 | Nested tool-result content and reasoning redaction | Pending |
| 6 | Checkpoint encoding, restore and metadata validation | Pending |
| 7 | Provider/endpoint/model rotation and replay eligibility | Pending |
| 8 | Multimodal tool-result projections and user attribution | Pending |
| 9 | Count/preview versus frozen generation input | Pending |
| 10 | Cancellation, resumed state and stale checkpoint writes | Pending |

## Round 1: malformed context cannot become new user evidence

Counterexample: a User-role checkpoint message contains the typed runtime
context key with an invalid value or more than one occurrence. The memory-search
repair excludes it, but `Keeper_librarian.message_to_text` treated both cases as
ordinary conversation. Thus its injected body reached both the Librarian prompt
and `observations_for_absorption` under an ordinary speaker header.

Repair: omit both bodies while preserving message positions, distinguish
invalid/duplicate provenance explicitly in the header, and keep marker-looking
text from an untagged real user unchanged. The existing behavioral scenario now
covers all four tagged classifications through prompt variables, rendered
Librarian request and absorption observations. No canonical message is changed.

Execution: parser and focused behavior results will be recorded separately.
