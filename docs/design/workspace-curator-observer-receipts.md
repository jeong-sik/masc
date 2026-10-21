# Original Curator observer intents

The Curator adapter can prepare observation without a live worker or Runtime.
It freshly loads the original owner, observes the physical workspace and
restores the complete acknowledged ancestry before touching an observer intent.
It never creates a missing request. The existing workspace process lease and
serialized owner must cover the whole operation.

`Workspace_memory_observation_receipt` gives the generic canonical observer
payload a Curator-specific meaning. Registration binds a deterministic run ID
to the original request/digest, complete capture input, configured installation,
package/tool and physical actor path. The input includes original rendered
prompt bytes, effective template and captured destination revisions; today's
configuration or prompt does not replace them. Package/tool identifiers now
have one source in Capture and are reused by the existing Exact validator.

Completion derives from the actual original phase. Finished requires the strict
Answered final, full semantic validation and exactly the original expected
before/after commit plan. Settlement and observation share this same pure
Capture.commit_plan. A model answer in Judged or an uncertain commit is not
success. Conflict validates the complete original domain state and retains that
evidence with the original plan.
Before-dispatch refusal remains distinct from a strict original execution
terminal, including unknown. A parent's same refusal survives successor linking
and cannot become its child's result. Each child has its own original run ID.

The answering slot and basic input/output usage come only from the retained
Answered final. Missing cache usage, cost, provider start and actual duration
remain absent. First observer wall time is labeled as observation, not provider
execution. Clock rollback neither creates a measured duration nor invalidates
the original observation. The generic receipt digest binds the entire first
time/payload; completion additionally binds the original registration digest.

`prepare_observation` obtains a clock value only for a new intent. Reopening
pending or acknowledged records reconstructs the expected complete typed
payload from the original capture and current legal phase, compares it to the
retained receipt, and returns it without appending or refreshing its time.
A generic valid hash alone cannot relabel run ID, original input, phase result,
slot or first time. Completion requires the same already retained registration.
It can be prepared while registration ACK is pending; the existing generic
fold still requires registration ACK before completion ACK. Initial start and
terminal intents are separate original journal publications: uncertainty after
either requires fresh load, never another request ID or guessed absence.

This port performs only observer intent publication. It does not read/write a
run registry, record an ACK, call a model or worker, save a domain, narrow,
change admission, or start production scheduling. Off with an existing owner
does not prevent local intent recovery; it grants no new work authority.
Historical ACKs are preserved and are not revoked by later registry retention.

The next registry integration must compare registration and terminal under its
own existing mutation lock, distinguish durable from volatile/unreadable state,
and avoid overwriting a genuine producer terminal. Replay-generated interruption
needs closed provenance and an explicit correction/history policy. Actual
duration must support absence through registry, statistics and strict UI
consumers; a zero would invent latency. Basic usage stays in the original final
while unavailable extended statistics remain absent. Production Curator still
uses its old direct provider route and must be replaced after these dependencies.

Nine new real-Store/domain scenario sources cover pending intent through actual
commit, unchanged byte/identity on reopen, full slot/basic usage and honest absent
timing, valid generic but false domain receipts, invented commit/incomplete
judgment refusal, parent/child separation, conflict versus unsent refusal, and
Briefing's original prepared-state plan. They do not exercise a run registry,
actual provider, installation On/Off, production scheduler or UI. Parser/source
review and compiled fixture execution are separate evidence.
