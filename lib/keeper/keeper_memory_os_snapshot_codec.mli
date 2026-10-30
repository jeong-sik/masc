(** Pure snapshot wire format and consistency validation.
    The current-store module owns file paths, JSON text parsing, and I/O. *)

val source_kind_to_string : Keeper_memory_os_current_types.source_kind -> string

val source_to_json : Keeper_memory_os_current_types.source -> Yojson.Safe.t
val source_of_json :
  Yojson.Safe.t ->
  (Keeper_memory_os_current_types.source, Keeper_memory_os_types.wire_error) result

val change_to_json : Keeper_memory_os_current_types.change -> Yojson.Safe.t
val change_of_json :
  Yojson.Safe.t ->
  (Keeper_memory_os_current_types.change, Keeper_memory_os_types.wire_error) result

type snapshot_rejection
(** A malformed wire value or an internally inconsistent snapshot. *)

val snapshot_rejection_to_string : snapshot_rejection -> string

val to_json : Keeper_memory_os_current_types.t -> Yojson.Safe.t
val snapshot_bytes : Keeper_memory_os_current_types.t -> string
(** Pretty-printed JSON followed by one newline. Publication digests and
    snapshot writes must use these same bytes. *)

val of_json :
  Yojson.Safe.t -> (Keeper_memory_os_current_types.t, snapshot_rejection) result
(** Validate the complete snapshot, including support closure and the relation
    between its current facts and recorded change. *)
