(** Immutable original explicit-candidate parts and two-child publication.
    Caller holds the original workspace lease and Memory-lane/purge fence and
    serializes the complete operation. All Store work is blocking; offload the
    whole scope in Eio. These ports never call a provider, save Memory or ACK
    queue candidates. Root overlap remains conservative: qualified replacement
    of a terminal deferred frontier after new input/material Memory change is
    a separate required integration boundary, not yet granted by this API. *)
type part
type inventory
type size_evidence

type gate_restore =
  parent_execution:Keeper_librarian_admission_capture.t ->
  gate_request_id:string ->
  (Keeper_librarian_absorb_gate.run_result, string) result
(** Trusted host port only: strictly restore the original gate journal and its
    physical owner, original parent execution/proposal and complete before/
    returned transcripts through Gate.restore. Never accept observer JSON,
    worker decisions, current configuration or a retry. *)

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

val discover : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  (inventory, string) result
(** Strict complete inventories: every part/partition, physical identity,
    original execution proof, exact Queue.split children, ancestry, cycles,
    unique ownership and disjoint root candidates are checked before
    returning. Pending transactions may have zero/one/two children; acknowledged
    transactions require both. Nothing is repaired or written by discovery. *)
val roots : inventory -> part list
val runnable : inventory -> part list
(** Original left-before-right leaf traversal. Children are runnable only
    after their exact two-child transaction is acknowledged. A parent with a
    pending transaction is not independently runnable. *)
val find : inventory -> part_id:string -> (part, string) result
val load_parent : inventory -> request_id:string ->
  (Keeper_memory_admission_queue.batch, string) result
(** Only roots or children with fully acknowledged ancestry may be used to
    restore an execution. A pending child never grants dispatch authority. *)

val retain_root : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner -> restore_gate:gate_restore ->
  part_id:string -> destination:Keeper_librarian_admission_capture.destination ->
  batch:Keeper_memory_admission_queue.batch -> admit:admit -> (part, string) result
(** Validate the complete current forest and fresh live admission before
    retaining an immutable root. No overlapping original candidate may acquire
    a second root owner. Same ID/input is idempotent; progress never resets. *)

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
