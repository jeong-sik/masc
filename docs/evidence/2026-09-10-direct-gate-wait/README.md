# Direct Gate waiting journal

This is the state/Owner part of direct Gate continuation, stacked on the runtime
resume unit. It does not yet connect model tool deferrals or Gate wake delivery
to direct-turn resumption. That dependent dispatch/admission part remains required
before this can change the observed live behavior.

The original queued operation retains its full input while a semantic Gate wait
binds its checkpoint and approval ID, tool name and canonical input hash. An
unresolved wait is excluded from claimable FIFO work, so the Owner does not
spawn repeated empty children. Later independent queued work can run. A matching
typed resolution makes that same operation claimable; a different approval or
checkpoint cannot resume it. Outstanding Gate obligations are a simultaneous
record field, so a runtime retry cannot replace and lose them. Completion is
rejected until the evidence obligations are discharged. The approval queue now
exposes a read-only typed observation of the authoritative request and decision,
including denial, without inferring a decision from absence.

Three SQLite behavior cases cover independent work, restart, matching approval
and denial, mismatched identities, pre-evidence completion refusal, runtime
fallback retaining Gate references and uncertain commit readback. The tests are
written, not locally run. Source-only parsing and `git diff --check` passed; no
local build ran. Exact-head CI is required.

The next dispatch part must retain the original owned checkpoint and preserve
newer independent history through existing approval-input CAS admission. It must
reuse the one-shot effect replay and keep the original request/channel/input.
An unchanged-canonical-only admission would incorrectly reject ordinary work
performed while waiting. Ask remains outside this Gate slice.
