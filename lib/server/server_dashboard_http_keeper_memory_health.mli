(** Read-only fleet health over the ordinary and source-bound current snapshots
    recall consumes. *)

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t

val fleet_cache_key : base_path:string -> string
(** The key the route caches {!keeper_memory_health_http_json} under. A
    write to one of its inputs empties it before the write is announced, so a
    fleet read after the announcement does not answer older than the row read
    it announced (RFC-0487 §2.8). *)

val keeper_memory_health_row_http_json : base_path:string -> keeper:string -> Yojson.Safe.t
(** [keeper]'s row alone, as [{"schema", "generated_at", "keeper"}] where
    ["keeper"] is the element {!keeper_memory_health_http_json} carries for
    it under ["keepers"], or [null] when the fleet answer has no row for
    [keeper] (it left, or never had one). The name is matched against the
    Keepers that answer lists, so it never names a file on its own. *)

(** Complete current snapshots grouped by canonical keeper identity for a
    workspace memory curator. Read-only: source file bindings are reported as
    stored, never presented as revalidated. Missing and unreadable stores are
    distinct. There is no atomic cross-keeper snapshot or synthesized revision. *)
val workspace_memory_context_http_json : base_path:string -> Yojson.Safe.t
