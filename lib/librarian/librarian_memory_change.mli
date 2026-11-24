(** The fact changes of one committed log sequence. Compaction keeps this
    projection without retaining prompts, working state or discarded proposals. *)
type t =
  { seq : int
  ; revision : int
  ; at : float
  ; line_at : int
  ; source : Keeper_memory_os_current_types.source
  ; added : Keeper_memory_os_types.fact list
  ; removed : (Keeper_memory_os_types.fact * Librarian_effects.removal) list
  }

val of_commit : line_at:int -> Librarian_log.commit -> t
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, Keeper_memory_os_types.wire_error) result
