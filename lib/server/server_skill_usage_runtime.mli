val install : unit -> unit
(** Retain the immutable ledger returned by each committed Skill writer. *)

val read_sessions :
  config:Workspace.config ->
  (string * Keeper_id.Trace_id.t) list ->
  (string * Keeper_skill_activation_ledger.t) list * string list
(** Read cold sessions once and reuse their committed ledgers. The second
    list keeps the original per-Keeper unavailable diagnostics. *)

val usage_for_reference : config:Workspace.config -> trace_id:Keeper_id.Trace_id.t ->
  reference:Skill_reference.t -> Keeper_skill_activation_ledger.catalog_usage option
(** Project one exact reference from the session cache, recomputing only after
    that session commits a different ledger. *)

module For_testing : sig
  val with_runtime :
    ?usage_projection:(Keeper_skill_activation_ledger.t -> Skill_reference.t ->
      Keeper_skill_activation_ledger.catalog_usage option) ->
    ledger_loader:(config:Workspace.config -> trace_id:Keeper_id.Trace_id.t ->
      (Keeper_skill_activation_ledger.t, Keeper_skill_activation_ledger.store_error) result) ->
    (unit -> 'a) -> 'a
end
