(** Immutable original explicit-candidate parts and two-child publication.
    Caller holds the original workspace lease and Memory-lane/purge fence and
    serializes the complete operation. All Store work is blocking; offload the
    whole scope in Eio. These ports never call a provider, save Memory or ACK
    queue candidates. Historical captures remain readable after an explicitly
    qualified terminal frontier is replaced, until the whole forest closes
    after complete committed-receipt and queue-ACK proof; only the active
    frontier runs. *)
type part
type inventory
type size_evidence
type supersession_proof
type terminal_source =
  | Original_execution of { part_id : string; execution_id : string }
(** References only, never caller grants. Every referenced execution is
    independently restored and checked against its complete original part. *)

type admit =
  destination:Keeper_librarian_admission_capture.destination ->
  publish:(unit -> (unit, string) result) -> (unit, string) result
(** Fresh configured Runtime publication authority must call [publish] inside
    its original serialized admission callback. An Ok without publication does
    not create authority. No worker boolean or manual destination substitutes. *)

val scope : Keeper_librarian_admission_capture.owner -> string
val partition_scope : Keeper_librarian_admission_capture.owner -> string
val is_scope : string -> bool
val is_partition_scope : string -> bool
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
val validate_payload_forest :
  read_scope:(scope:string -> (Lane_addon_tool_request_owner.retained list, string) result) ->
  owner:Keeper_librarian_admission_capture.owner -> (unit, string) result
(** The runtime's structural forest checks over verified captured inventories:
    partition ancestry, children and pending publication shape, unique
    ownership, replacement lineage and disjoint active roots. Does not read
    Current, execution receipts or live owner state, or recover publication. *)
val load_parent_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  owner:Keeper_librarian_admission_capture.owner -> request_id:string ->
  (Keeper_memory_admission_queue.batch, string) result
(** Pure current payload/binding and acknowledged-ancestry checks over an
    explicit read-only original-record port. Does not inspect current Memory,
    supersession receipt status, live ownership or perform recovery. This is
    insufficient authority for execution; runtime uses {!discover}. *)
val payload_inventory :
  read_scope:(scope:string -> (Lane_addon_tool_request_owner.retained list, string) result) ->
  owner:Keeper_librarian_admission_capture.owner -> (inventory, string) result
(** The forest {!validate_payload_forest} checks, once it passes. *)

(** How a forest reading reaches an original execution. {!discover} reads the
    store; the deploy check reads the files the Exact check leaves. *)
type execution_reads = {
  load : request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result;
      (** The original execution record of this ID in the owner's execution
          scope. *)
  read_latest : declaration_id:string -> schema:Yojson.Safe.t -> Lane_addon_exact.request ->
    (Lane_addon_exact.latest_original_execution, string) result;
      (** The latest attempt the execution's host evidence shows, as
          {!Lane_addon_exact.read_latest_original_execution} answers. *)
  confirm : Keeper_librarian_admission_capture.t -> Lane_addon_exact.final -> (unit, string) result;
      (** {!Keeper_librarian_admission_capture.confirm_final} of the final. *)
}
val check_partition_proof : reads:execution_reads ->
  owner:Keeper_librarian_admission_capture.owner ->
  inventory:(unit -> (inventory, string) result) ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
(** The check {!discover} applies to this partition record: the size proof it
    retains must equal the one its source execution shows through [reads].
    [inventory] is called once the record decodes. *)
val check_frontier_evidence : reads:execution_reads ->
  owner:Keeper_librarian_admission_capture.owner ->
  inventory:(unit -> (inventory, string) result) ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
(** The check {!discover} applies to the frontier witnesses of this part
    record when it is a root that replaces an earlier frontier: each retained
    witness must equal the one its execution shows through [reads]. Any other
    part passes without calling [inventory]. *)

val discover : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
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
val completion_candidates : inventory -> Keeper_memory_os_current.explicit_candidate_id list option
(** [Some ids] only for a nonempty forest whose partitions are all acknowledged
    and whose active leaves exactly cover its active roots. Includes candidate
    identities from historical parts too. This structural observation is not
    execution completion, committed-receipt proof or queue ACK: the owner must
    independently establish all three before closing the forest. [None]
    preserves an empty or incompletely published forest. *)
val find : inventory -> part_id:string -> (part, string) result
val load_parent : inventory -> request_id:string ->
  (Keeper_memory_admission_queue.batch, string) result
(** Only roots or children with fully acknowledged ancestry may be used to
    restore an execution. A pending child never grants dispatch authority. *)

val prove_supersession : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
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
  owner:Keeper_librarian_admission_capture.owner ->
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
val partition : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  parent:part -> evidence:size_evidence -> partition_id:string ->
  left_id:string -> right_id:string -> admit:admit ->
  (part * part, string) result
(** Freshly verify evidence and complete forest before a new intent under
    mandatory live admission. The existing Owner/Progress journal retains the
    original proof and both full immutable children as one commit intent,
    strictly confirms each child, then acknowledges that exact intent. No
    speculative Memory/prompt capture is created for either child. *)
val recover_partitions : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  (inventory, string) result
(** Resume only existing original transaction IDs/children, including while
    Off. Interruption after one child reuses that same ID. Acknowledged missing
    children refuse rather than being recreated. Publication uncertainty is an
    error requiring a new strict read, never a replacement transaction/ID. *)
