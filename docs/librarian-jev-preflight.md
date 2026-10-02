# Librarian JEV no-change preflight

The Librarian's Memory-only pass can ask JEV whether the exact supplied
memory-selection request warrants any change. Explicit opt-in in the loaded
runtime.toml enables it:

```toml
[typesafeai]
librarian_preflight = true
```

The declared lane, destinations, credentials and Keeper exclusions still
apply. The setting defaults to false. It sends the rendered memory-selection
request to the configured destination; the existing Board opt-in does not
enable this input path.

Only `Memory_pass None` with an empty working-context input is eligible.
Continuity, working-context generation and any Memory pass carrying working
context use the existing text-generating lane. JEV selects `keep_current`,
`needs_generation` or `uncertain`; it does not create a claim, Category name
or continuity summary. No unmeasured confidence cutoff is introduced.

A decoded `keep_current` decision is translated into an empty delta and
validated by the existing Librarian parser. An accepted delta follows the
normal snapshot disposition and range-receipt writer. Validation refusal,
`needs_generation`, `uncertain`, unavailable configuration, transport failure
and malformed answers use the full lane. Cancellation propagates.

The existing run registration persists its input before any JEV call. Terminal
output includes `jev_preflight` with decision, probabilities, confidence,
elapsed time, answering model, destination and exact request-body hash.
`generation_path` distinguishes `not_entered`, `full_lane` and
`jev_no_change`. `full_lane` means entry to the generation pipeline, not a
measured count of provider requests: projection/admission may refuse before
dispatch and failover may send several requests. `full_llm_skipped` states
that the no-change branch was accepted. `preflight_domain_rejection` records
why a no-change selection had to fall back. A JEV answer never claims an
exact-output catalog slot or official-client runtime as its answer source.
Awaiting/cancelled evaluation is separate from a received answer; only real
received client evidence provides model and request hash. Existing client
failure observations can contain provider response bodies.

## Verification and measurement

`test/test_keeper_librarian_preflight.exe` exercises the actual effect boundary
with synthetic HTTP and an official-client runner: no-change skips generation,
preserves Memory and records its normal receipt; generation-needed, uncertain,
invalid and failed responses call the full lane; opt-out, excluded and context
units do not call JEV. Fixture decisions establish routing, not JEV quality.

Measure performance with the same frozen inputs and configuration for baseline
and preflight, recording actual generation calls, paired end-to-end timings,
classification and constraint/obligation preservation. A new JEV call adds
work on fallback paths; it is useful only if avoided generation compensates
for that work without semantic regressions. Keep fixture timings, live JEV
measurements and installed production proof distinct. Native typing and
execution must be reported separately from source review.

Workstream: Goal `goal-1790911534058-d6e92111`, Tasks `task-2021`–`task-2023`,
Board `p-fa803593a06a90a3f5a50849ee6f13a6`, issue #40755. No historical-record
compatibility or migration is part of this change.
