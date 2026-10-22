# Exact run observation origin and timing

Exact run observations retain the original input/output separately from their
payload availability. A missing measurement is also separate from a measured
zero. This contract is groundwork for delivering Curator's original observation
receipts; it does not yet implement that delivery or acknowledge its outbox.

`Exact_lane_run_registry.Completed` records a closed `Producer | Restart_replay`
origin and `elapsed_s : float option`. The existing measured `mark_completed`
API takes a finite nonnegative float and records `Producer` with `Some elapsed`.
It refuses invalid durations before payload or row publication. A running
observation closed during replay records `Restart_replay` with no duration,
slot or provider usage. That observation says a fiber did not survive restart;
it does not declare the original durable domain request finished or authorize
dispatch or settlement.

`mark_completed_unmeasured` records an actual producer terminal with no original
duration. Candle uses it when recovering the original worker terminal after a
restart; downtime cannot be counted as a measured execution duration. A failed
publication retry preserves the same optional duration, including absence.

The persisted current format is `exact-lane-runs-v7.jsonl`. Completion `origin`,
nullable `elapsed_s`, and nullable `usage` are required. Unknown origin, negative
or nonfinite duration, and replay origin with invented measurement or producer
content are malformed. Replay origin must retain the registry's exact restart
outcome and inline observation. A producer's failure code may itself say
`server_restarted`; that string does not grant replay provenance.

Payloads belong to `exact-lane-run-payloads-v7/`. Cleanup walks only that root;
it cannot delete another generation's files using the new log's retained set.
Existing v6 log and payload files are left untouched and are not read or
migrated by this generation. This is an observation format boundary, not deletion of Curator's
original durable journals, receipts, or execution obligations. Absence from the
new registry cannot revoke an original acknowledgement or authorize reexecution.
The new generation's clean startup is not a receipt for current on-disk
durability.

HTTP terminal summaries and details require `completion_origin`, nullable
`elapsed_s`, and nullable `usage`. Running rows omit all terminal fields. The
Dashboard parser preserves that absence and the complete reported usage
contract, including both cache counts and optional cost. It rejects missing,
unknown or incomplete current fields. The TUI's existing optional-duration
decoder receives the registry's actual summary/detail projection without
turning null into zero; the focused consumer test checks decoded data, not
screen wording or layout. Neither a passing decoder nor this source change
proves the installed UI.

Standalone latency p50 includes only measured durations. Known completions
retain their measured finish ordering. An unmeasured completion uses its
original registration time as an explicit ordering anchor; a first observer
may register a request after that request actually finished. This is neither
an execution-start claim nor inferred chronology for mixed known/unknown
finishes. Equal anchors use stable registry-source and original-run identity,
independent of traversal order. If the selected terminal is unmeasured,
`last_terminal_at` remains null.

Candle's retained completion checks use origin rather than guessing from an
error-code string. A different genuine producer receipt or pending receipt is
reported as a conflict and preserved. A matching failed publication retries
the original measured duration; absence is not replaced with zero or the retry
clock. An ordinary measured Candle duration describes its host observation interval;
it is not a provider-reported model execution duration. A newly discovered
retained terminal cannot reconstruct a prior provider clock. The existing
read/compare/write sequence is not an atomic registry
reconciliation transaction.

The next delivery unit must use authoritative current disk state under registry
serialization, distinguish absence from unavailable source, confirm actual
durability, compare the full immutable original intent, and acknowledge the
original owner only after that confirmation. It must preserve uncertain writes,
retention policy, and restart audit evidence. Memory projection, clean replay,
an available null payload, and matching bytes alone are different facts. This
foundation does not claim those delivery guarantees, actual provider execution,
Docker lifecycle, integration, or installation.
