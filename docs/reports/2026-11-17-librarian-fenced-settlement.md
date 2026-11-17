# Keep settlement under the original effect fence

The direct `settle_refused` API could write an empty range receipt and advance
source ACKs after an original had been effect-fenced. Its caller normally uses
this API for a permanent counterpart-capacity refusal, but the API itself also
accepted an execution-stage Cut. A retained effect fence must deny both paths.

Refusal settlement now checks the same original fence while holding its source
locks before any Memory receipt write. The shared ACK path holds those locks
from its fence check through external, atom and official acknowledgement. A
fence cannot enter between that check and those writes.

ACK recovery can start after some frontiers have already moved. The settlement
lock scope preserves the existing strict captured-or-settled frontier checks
and actual Memory-receipt checks; it checks the physical owner without reading
the history prefix again. Once Memory has proved that prefix, retention may
have pruned its checkpoint. That does not authorize inference or a new Memory
effect and does not prevent finishing the already proved ACK.

The existing atom-only and mixed-source Cut fixtures now call direct refusal
settlement after fencing and require no Memory or frontier change. One added
fixture uses actual Memory receipts, acknowledges the external frontier first,
prunes the checkpoint prefix and completes the remaining atom ACK without
another model call or Memory revision. It models a partially settled boundary,
not a real process-kill experiment.

At authoring, parsing and whitespace checks passed. Type checking and the
behavior fixtures have not run. Source review and live deployment/recovery
remain separate evidence.
