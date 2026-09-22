(** The last provider-reported character capacity for one Keeper's
    Librarian lane. This is observed evidence, not runtime configuration. *)

type t =
  { runtime_id : string
  ; actual_chars : int
  ; max_chars : int
  }

val load : keepers_dir:string -> keeper_id:string -> (t option, string) result
val save : keepers_dir:string -> keeper_id:string -> t -> (unit, string) result
