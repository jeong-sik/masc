(** Fresh history selection cannot bypass an unresolved Cut by minting an
    unparented request or running continuity. Call inside the existing serialized
    Memory owner. Absence fences retain their existing next-pass semantics. *)
type error = Unresolved_cut of string | Unavailable of string
val error_to_string : error -> string
val check : config:Workspace.config -> keeper_name:string -> (unit, error) result
(** Reads the authoritative fence namespace, not just surviving owner records.
    No recovery, original/body creation, provider call or source consumption.
    This source unit grants no Cut successor, so every retained Cut blocks
    fresh history selection. *)
