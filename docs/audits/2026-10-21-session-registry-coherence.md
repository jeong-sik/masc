# Coherent MCP transport-session registry

The HTTP session module published protocol, profile, last activity, start time and
transport through five independent atomic maps. The persistence worker mutex
serialized file operations, but did not serialize live registration. A capture
could therefore combine versions and telemetry from different updates, or save
an initialized session before activity was published, using the existing `0.0`
missing-field fallback. This is a source interleaving, not an observed failure or
an explanation proven for the installed TUI Loading report.

| Operation | Before | After |
| --- | --- | --- |
| Valid protocol registration | Version followed by activity/start/optional transport updates | One immutable registry transition for those related fields |
| Profile registration | Profile followed by a separate known-session check and activity update | Profile and any known-session activity commit together |
| Save and duration observation | Independent field-map reads | One committed registry capture per operation |
| Successful restore | Up to five field-map CAS updates | One CAS merges the immutable worker patch into the current state |
| Forget | Five field removals after lifecycle effects | All local fields removed together after the same lifecycle effects |

Each map retains its previous independent presence/default policy. A profile-only
entry is still unknown to the successful-initialize predicate and excluded from
saved sessions. The stored matching Seat/Operator_remote profile still permits
that narrow DELETE gate even before initialize; general profile validation still
accepts absence. No implicit new Full authority is introduced. Separate public API
calls remain separate transitions. Valid registration retains the first start,
refreshes activity and replaces a present transport object whole; absent transport
retains prior context. Unsupported versions and rejected initialize responses do
not register. Duration emission and external client unregister still precede the
local forget, outside the registry transition.

The decoder prepares the same five field maps, now in a private registry patch.
Mandatory values retain last-valid and optional values last-present duplicate
policy, timestamp defaults and restored-value collision priority. One caller CAS
after the existing cancellation/ownership checks merges with the latest state on
every retry; unrelated live keys survive. A patch with no valid protocol rows
skips publication while still completing normal restore bookkeeping. The decoded
entry count is diagnostic only. Regular-file boundaries, path/process refusal,
first-cause retention, tokens, host mutex and typed persistence results remain.
Public function signatures, wire shape and runtime prompts are unchanged.

The source counts above describe logical update/capture boundaries, not disk I/O,
CPU, readiness or input speed. Clocks stay outside retry callbacks. Profile-only
registration now also reads the clock once. Larger immutable records allocate;
updates to unrelated fields now contend on one atomic value, and CAS retries can
repeat pure tree construction and up to five unions. Existing host/executor/lock,
file/decode and readiness costs remain. No request-side blocking mutex, timer,
cache, knob, arbitrary iteration limit or fsync guarantee is added.

Two authored, unexecuted actual protocol/resource scenarios extend thirteen to
fifteen cases. One sends actual initialize JSON through the production admission
helper, checks profile-only/rejected/accepted authority with real snapshots, then
refreshes, deletes, re-registers and restores. The other starts a native Domain
producer using only registration APIs while the caller saves/reads real files;
any captured initialized row must retain a matching protocol/transport pair and
real activity/start. It joins once on success or failure, saves the final state
and restores that session plus an unrelated peer. It uses producer completion,
without sleeps or a stress count. Scheduling may finish the producer before a
save overlaps; authored concurrency is neither a deterministic old failure
reproduction nor evidence of executed overlap. These are behavioral resource
cases, not helper/count/UI wording/layout tests. The test's direct
`masc.otel_dispatch_hook` library is declared explicitly.

Only parsing of the changed interface, implementation and scenario file is
allowed/performed for this unit. No types, warnings, linking, Dune, test execution,
CI dispatch/watch, server/controller/native TUI/model/PTY, installation, restart,
visible paint, latency samples, independent approval or merge is established.

| Original goal axis | Evidence still required |
| --- | --- |
| Original Ask to Task to useful work | Actual original identity and useful-work continuity |
| Preparation attribution and frozen discovery | Matched real attribution/reuse samples including preparation cost |
| Ordinary/nested/dynamic/effectful Composition | Actual shared resource lifetime and completion continuity |
| Held reactivation and shared-backend batch | Actual reactivation and batching behavior |
| Cold usable input, readability and observations | Matching installed source/binary, physical/caller/UI events and visible TUI |
| Matched Before/After | Actual cohorts retaining failed/cancelled/interrupted/not-started/unfinished attempts |

This is one source repair for the coherence finding in #44417 review
5588662113 section 4. Independent acceptance and all unobserved evidence above
remain open. The separate agent-session lazy-restore boundary remains outside
this transport registry repair.
