(** Strict storage binding for ordered programs, including journal-prefix
    identity and unchanged-revision byte identity. Decode is validation of
    evidence, not authority to write or to consume an input boundary. *)
val to_json : Keeper_memory_os_program_types.publication -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_memory_os_program_types.publication, string) result
(** Existing single-kind proofs retain schema 1; a shallow Mixed boundary has
    schema 2 with exactly one atom and one official component. *)

val store_anchor_to_json : Keeper_memory_os_program_types.store_anchor -> Yojson.Safe.t
val store_anchor_of_json : Yojson.Safe.t -> (Keeper_memory_os_program_types.store_anchor, string) result
(** Pure exact store-anchor data codec. Live rejoining belongs to Current. *)

val require_receipt_ranges :
  Keeper_memory_os_program_types.publication ->
  Keeper_memory_os_current_types.consumed_range list -> (unit, string) result
(** Exact original-boundary set for this program, including each kind's unread
    projection. Mixed requires both components and no extra or repeated range.
    This validates data only, not durability, source ownership or ACK authority. *)

val touched_ids : Keeper_memory_os_program_types.publication -> string list

val validate_transition
  : Keeper_memory_os_program_types.publication
  -> source_trace_id:string
  -> revision:int
  -> added:Keeper_memory_os_types.fact list
  -> removed:Keeper_memory_os_types.fact list
  -> retained:int
  -> (unit, string) result
(** Bind the actual outer delta to locked initial/final facts. Transient
    invalidations and drops belong to the ordered steps, not this delta. *)
