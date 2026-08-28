(** Exact-revision Skill evidence joined from the current Keeper activation
    ledgers and the durable composition tool-call log. *)

val project : config:Workspace.config -> Skill_reference.t -> Yojson.Safe.t

module For_testing : sig
  val to_yojson :
    reference:Skill_reference.t ->
    composition:Yojson.Safe.t option ->
    composition_records_read:int ->
    composition_scope:[ `Exact_reference_latest_completed | `Unavailable ] ->
    activation:(string * Keeper_skill_activation_ledger.activation) option ->
    ledgers_loaded:int ->
    unavailable:string list ->
    Yojson.Safe.t
end
