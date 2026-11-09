# RFC-0515 remaining views: retained observation

The [baseline bundle](baseline/README.md) contains actual sanitized tmux text
captures at 120×35 and 80×24 from installed build
`6a6ec4c28e2f26edcf272e37115ac2f655005f2b`. It is not an execution of the
implementation stack. Its original manifest bytes are preserved;
[current locations](current-locations.json) locate these retained derivatives. `baseline-path-digests.json` is a derived
path/digest index for the location checker, extracted from the original
manifest file map; it is not a new capture or binary attestation.

The source work follows #50578: V5 → V4 → G4 → V8 → W1. Source review,
parse-only checking, GitHub type checking, and candidate execution are separate
evidence. The [frozen candidate bundle](candidate-ea87978/README.md) adds actual
after captures, same-width comparisons, exact-source checks and their limits.
Later restacked source is distinguished from the executed candidate.

New runs are written under `artifacts/rfc0515-remaining-20261109/`, outside
this retained bundle. The read-only capture runner isolates local preferences
and rejects upstream mutations. See the baseline README for the exact runtime
observation windows and redactions.
