(** Strict storage binding for ordered programs, including journal-prefix
    identity and unchanged-revision byte identity. Decode is validation of
    evidence, not authority to write or to consume an input boundary. *)
val to_json : Keeper_memory_os_program_types.publication -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_memory_os_program_types.publication, string) result

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
