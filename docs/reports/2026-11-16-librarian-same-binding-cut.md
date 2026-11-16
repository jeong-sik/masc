# Same-binding history Cut recovery

This followup uses the existing open issue #50828. Its first native layer is
based on `4778ce6957bcf37963875563e276cb006eaad501`, the prior ten-layer
Librarian candidate. The declaration-replacement contract remains unchanged.

The runtime owner's retained observations identify two history originals:
context-reviewer `d91b` and rondo `b523`. Their host/worker IDs and input digests
match, both outcomes remain Unknown, and resolution preview was ineligible with
no fence or intent. Replacing a host or worker does not change the semantic
configuration revision and does not authorize another request.

The private observation packet is at
`artifacts/keeper-repair-20261116/same-binding-cut-followup.md`, with
`post-oom-unknown-reconciliation.json` and
`post-external-upgrade-pending-record-preservation.json`. These observations do
not establish an execution exclusion capability or actual recovery. This unit
performs no live retry, configuration change, original deletion, Memory or ACK
write.

## First source unit: hold the real original claim through a callback

`recover_retained` falls back to observation when another caller owns its claim.
A successful observation therefore does not prove that the caller owns the
claim. The new Exact API distinguishes Busy and verifies a terminal Cut while
holding the same claim used by execution and recovery. Only a strict Cut with
no completed latest execution enters its consumer callback. All attempt/proof
bindings and the captured request/schema are checked first. Other terminals,
open and absent originals never enter that callback; malformed or unreadable
proofs are errors.

The witness expires when the callback returns, raises or is cancelled.
`confirm_cut_exclusion` checks its active lifetime, original identity/schema,
and unchanged record/proof observations immediately before a domain effect.
Strict fence publication and readback must finish inside the callback. The
witness is not a persisted source-unconsumed grant and does not prove remote
provider or CLI termination. Consumers still require their real workspace lease,
serialized Memory owner, source locks and domain checks.

Execution, recovery and the new guard share physical-path claim keys so a
store-path alias cannot acquire a second claim. Normalizing a key creates no
store or record. This source change has no measured latency claim.

The authored scenarios cover a paused synthetic host call through an aliased store,
callback reentry, observation versus exclusion, cancellation/error
release, expired witnesses, unchanged parent Unknown, different original
input, non-Cut terminals and a conflicting proof. These repository
regressions were not executed. Parser and source review do not establish type
safety or runtime behavior.

## Required next stages

| Boundary | Current evidence | Work still required |
| --- | --- | --- |
| Domain grant | Resolution and fence codecs admit only Dispatch-pending Absent | Persist a typed source-unconsumed Cut grant under the held claim and distinguish existing settlement/successor ownership |
| Actual effects | Production uses a serialized Memory lane and source, aggregate, snapshot, owner lock order | Publish and strictly confirm the fence in that unit, excluding late parent Memory/ACK effects |
| Prepared Memory publication | Locked snapshot and range-receipt checks refuse pending publication | Let the ordinary writer reconcile first; do not reenter recovery under the same locks |
| Body-staging crash | A child body is staged before its intent; each preparation mints an ID | Add a parent/intent-keyed write-once staging locator or an equivalent atomic prepare operation |
| Subdivision/floor completion | The current completion walk does not complete those parent states | Bind actual descendant range receipts and original source ACK to durable completion evidence |
| Receipt retention | Rows are replaced by the latest range of their scope | Capture genuine completion while its receipt exists; never invent prior coverage from cursor maxima or a missing row |

The first source unit does not complete same-binding Cut recovery or recover the
two live originals. Current-main integration, type checking, Dune builds,
regression execution, CI, installation, actual recovery and performance remain
unverified.
