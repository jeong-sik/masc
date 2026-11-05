(** Read-only fleet health over the ordinary and source-bound current snapshots
    recall consumes. *)

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t

val keeper_memory_health_row_http_json :
  base_path:string -> keeper:string -> Yojson.Safe.t option
(** [keeper]'s row alone, as [{"schema", "generated_at", "keeper"}] where
    ["keeper"] is the element {!keeper_memory_health_http_json} carries for
    it under ["keepers"]. [None] when the fleet answer has no row for
    [keeper]; the name is matched against the Keepers that answer lists, so
    it never names a file on its own. *)

(** Complete current snapshots grouped by canonical keeper identity for a
    workspace memory curator. Read-only: source file bindings are reported as
    stored, never presented as revalidated. Missing and unreadable stores are
    distinct. There is no atomic cross-keeper snapshot or synthesized revision. *)
val workspace_memory_context_http_json : base_path:string -> Yojson.Safe.t
