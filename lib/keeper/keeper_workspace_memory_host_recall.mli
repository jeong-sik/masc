(** Host retrieval when the current request cannot call or load the shared
    reader. No memory mutation or broad briefing substitution occurs. *)
val render : config:Workspace.config -> keeper_id:string ->
  purpose:Yojson.Safe.t -> string
(** Honors the TypeSafe lane switch, credentials and Keeper exclusion. Model
    calls persist their request and response. Changed ledger/source evidence
    prevents publishing that selection; failures remain explicit. *)

type prepared
val prepare : config:Workspace.config -> keeper_id:string -> purpose:Yojson.Safe.t -> prepared
val render_prepared : prepared -> string
(** Revalidate selected source records before reusing the prepared projection. *)
val defer_for_capacity : prepared -> Keeper_memory_delivery_reprojection.t
(** Called only after a runtime authorizes an effect-safe retry for an explicit
    input capacity refusal. Persist and remove whole selected records only when
    the rendered projection becomes strictly smaller. Never rerun selection. *)

module For_testing : sig
  val prepare_projection : payload:Yojson.Safe.t ->
    validate:(Yojson.Safe.t -> (unit,string) result) ->
    retain:(reason:string -> payload:Yojson.Safe.t -> (unit,string) result) -> prepared
  val collect_with_snapshots :
    summary:(unit -> (Yojson.Safe.t,string) result) ->
    detail_snapshot:(unit -> id:string -> (Yojson.Safe.t,string) result) ->
    evaluate:Keeper_workspace_memory_selection.evaluate ->
    purpose:Yojson.Safe.t -> (Yojson.Safe.t,string) result
  val collect :
    ?is_excluded:(string -> bool) ->
    summary:(unit -> (Yojson.Safe.t,string) result) ->
    detail:(id:string -> (Yojson.Safe.t,string) result) ->
    evaluate:Keeper_workspace_memory_selection.evaluate ->
    purpose:Yojson.Safe.t -> unit -> (Yojson.Safe.t,string) result
end
