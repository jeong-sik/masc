val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Cross-subsystem keeper waiting/deferred read model for dashboard tools.
    This parent-library module is shared by server and tool entrypoints; it may
    join MASC stores, but it does not add a dashboard dependency to lower
    keeper/runtime libraries. *)

val dashboard_json_for_keeper :
  Workspace.config -> keeper_name:string -> Yojson.Safe.t
(** The same typed projection narrowed to one keeper for latency-sensitive
    detail surfaces. It does not overwrite fleet-wide waiting metrics. *)

module For_testing : sig
  val dashboard_json_with_pending_reader :
    read_pending:
      (base_path:string ->
      ( Keeper_approval_queue.pending_approval list
      , Keeper_approval_queue.storage_error )
      result) ->
    Workspace.config ->
    Yojson.Safe.t
end
