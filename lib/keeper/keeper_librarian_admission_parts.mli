(** Immutable original explicit-candidate parts and two-child publication.
    Caller holds the original workspace lease and Memory-lane/purge fence and
    serializes the complete operation. All Store work is blocking; offload the
    whole scope in Eio. These ports never call a provider, save Memory or ACK
    queue candidates. Historical captures remain readable after an explicitly
    qualified terminal frontier is replaced; only the active frontier runs. *)
type part
type inventory
type size_evidence
type supersession_proof
type terminal_source =
  | Original_execution of { part_id : string; execution_id : string }
  | Original_gate of { part_id : string; execution_id : string; gate_request_id : string }
(** References only, never caller grants. Every referenced execution/gate is
    independently restored and checked against its complete original part. *)

type gate_restore =
  parent_execution:Keeper_librarian_admission_capture.t ->
  gate_request_id:string ->
  (Keeper_librarian_absorb_gate.run_result, string) result
(** Trusted host port only: strictly restore the original gate journal and its
    physical owner, original parent execution/proposal and complete before/
    returned transcripts through Gate.restore. The complete same-owner gate
    inventory must establish that the requested gate is the unique latest
    original attempt for this execution; an earlier capacity result cannot
    bypass a pending or unknown successor. Never accept observer JSON, worker
    decisions, current configuration or perform a retry. *)

type admit =
  destination:Keeper_librarian_admission_capture.destination ->
  publish:(unit -> (unit, string) result) -> (unit, string) result
(** Fresh configured Runtime publication authority must call [publish] inside
    its original serialized admission callback. An Ok without publication does
    not create authority. No worker boolean or manual destination substitutes. *)

val scope : Keeper_librarian_admission_capture.owner -> string
val partition_scope : Keeper_librarian_admission_capture.owner -> string
(** Distinct original-owner/physical Memory-epoch namespaces, derived from the
    canonical complete owner identity. Not a second registry or index. *)
val part_id : part -> string
val batch : part -> Keeper_memory_admission_queue.batch
val destination : part -> Keeper_librarian_admission_capture.destination
val predecessor : part -> string option
val original_through : part -> int
val to_json : part -> Yojson.Safe.t
val validate_part_payload : owner:Keeper_librarian_admission_capture.owner ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
val validate_partition_payload : owner:Keeper_librarian_admission_capture.owner ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
val load_parent_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  owner:Keeper_librarian_admission_capture.owner -> request_id:string ->
  (Keeper_memory_admission_queue.batch, string) result
(** Pure current payload/binding and acknowledged-ancestry checks over an
    explicit read-only original-record port. Does not inspect current Memory,
    supersession receipt status, live ownership or perform recovery. This is
    insufficient authority for execution; runtime uses {!discover}. *)

val discover : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  (inventory, string) result
(** Strict complete inventories: every part/partition, physical identity,
    original execution proof, exact Queue.split children, ancestry, cycles,
    unique ownership, explicit replacement lineage and disjoint active-root
    candidates are checked before
    returning. Pending transactions may have zero/one/two children; acknowledged
    transactions require both. Full replacement validation reads Current
    receipt status and may reconcile its publication state; do not use this
    operation for deploy preflight. Use the pure payload ports above there. *)
val roots : inventory -> part list
(** Active roots only. Superseded immutable roots and their acknowledged
    descendants remain available to [find]/[load_parent] for historical reads. *)
val runnable : inventory -> part list
(** Original left-before-right leaf traversal. Children are runnable only
    after their exact two-child transaction is acknowledged. A parent with a
    pending transaction is not independently runnable. *)
val find : inventory -> part_id:string -> (part, string) result
val load_parent : inventory -> request_id:string ->
  (Keeper_memory_admission_queue.batch, string) result
(** Only roots or children with fully acknowledged ancestry may be used to
    restore an execution. A pending child never grants dispatch authority. *)

val prove_supersession : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  inventory:inventory -> batch:Keeper_memory_admission_queue.batch ->
  frontier:terminal_source list -> (supersession_proof option, string) result
(** Read actual complete pending input and current Memory revision/hash/facts.
    The references must cover every active acknowledged leaf exactly once.
    Completed semantic Deferred, singleton positively size-refused terminals,
    and Finished accepted work with exact committed candidate receipts qualify.
    Uncommitted old gaps must remain in the new complete pending batch; lost,
    unknown, malformed or ordinary failed work never grants a replacement.
    An actual new tail or materially changed original fact/provenance context
    is required for every remaining old gap. A revision/timestamp change alone
    is not new context. The proof retains original frontier/receipt/source
    identities, not a mutable pointer to the current queue or Memory. [None]
    means the complete original frontier is valid but unchanged, so no fresh
    root is authorized. Corrupt/unreadable/unknown/ordinary failure stays Error. *)
val retain_root : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  ?supersession:supersession_proof ->
  part_id:string -> destination:Keeper_librarian_admission_capture.destination ->
  batch:Keeper_memory_admission_queue.batch -> admit:admit -> unit -> (part, string) result
(** Validate the whole forest, actual full pending input and fresh live
    admission before retaining a root. Overlapping active input requires the
    exact opaque supersession proof; unchanged wakes cannot mint another root.
    Proof and predecessor links are retained atomically in this immutable part.
    Same ID/input is idempotent and never resets an old progress history.
    Publication rechecks actual pending/Memory evidence; later historical
    discovery validates captured evidence without borrowing today's pending
    batch as authority or resurrecting superseded roots. *)

val execution_size_evidence : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> inventory:inventory ->
  parent:part -> execution_id:string -> (size_evidence, string) result
(** Actual latest host Exact proof only: original Capture parent/destination/
    request/schema/ordinal binding and a named input-capacity terminal, without
    invalid-output or size-independent failure veto. Missing/unknown evidence
    is not size authority. *)
val gate_size_evidence : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> inventory:inventory ->
  parent:part -> execution_id:string -> gate_request_id:string ->
  restore_gate:gate_restore -> (size_evidence, string) result
(** Actual original answered execution plus the trusted strict original gate
    restoration port. Only Gate.Input_capacity_exceeded permits partition. *)

val partition : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  parent:part -> evidence:size_evidence -> partition_id:string ->
  left_id:string -> right_id:string -> admit:admit ->
  (part * part, string) result
(** Freshly verify evidence and complete forest before a new intent under
    mandatory live admission. The existing Owner/Progress journal retains the
    original proof and both full immutable children as one commit intent,
    strictly confirms each child, then acknowledges that exact intent. No
    speculative Memory/prompt capture is created for either child. *)
val recover_partitions : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  (inventory, string) result
(** Resume only existing original transaction IDs/children, including while
    Off. Interruption after one child reuses that same ID. Acknowledged missing
    children refuse rather than being recreated. Publication uncertainty is an
    error requiring a new strict read, never a replacement transaction/ID. *)
