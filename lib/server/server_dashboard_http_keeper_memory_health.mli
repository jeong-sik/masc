(** Read-only fleet health over the ordinary and source-bound current snapshots
    recall consumes. *)

type keeper_health

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t

val install : unit -> unit
(** Refresh only the changed Keeper after a durable journal commit. *)

module For_testing : sig
  val keeper_health : config:Workspace.config -> keepers_dir:string -> string -> keeper_health

  val with_runtime :
    keeper_health:(config:Workspace.config -> keepers_dir:string -> string -> keeper_health) ->
    (unit -> 'a) -> 'a
end

(** Complete current snapshots grouped by canonical keeper identity for a
    workspace memory curator. Read-only: source file bindings are reported as
    stored, never presented as revalidated. Missing and unreadable stores are
    distinct. There is no atomic cross-keeper snapshot or synthesized revision. *)
val workspace_memory_context_http_json : base_path:string -> Yojson.Safe.t
