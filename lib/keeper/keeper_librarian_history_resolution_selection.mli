(** Fresh history selection cannot bypass an unresolved Cut by minting an
    unparented request or running continuity. Call inside the existing serialized
    Memory owner. Absence fences retain their existing next-pass semantics. *)
type error = Unresolved_cut of string | Unavailable of string
val error_to_string : error -> string
val check_for_keepers_dir : base_path:string -> keepers_dir:string ->
  keeper_name:string -> (unit, error) result
(** The same guard for a commit adapter with an explicit Memory directory. *)
val check : config:Workspace.config -> keeper_name:string -> (unit, error) result
(** Reads the authoritative fence namespace, not just surviving owner records.
    No recovery, original/body creation, provider call or source consumption.
    Cut stays blocked until its matching command retains a genuine descendant
    Memory completion after source ACK. That compact proof remains sufficient
    after raw bodies and rolling receipts are pruned. *)
