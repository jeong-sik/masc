(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Routes:
    - GET  /api/v1/ide/annotations
    - POST /api/v1/ide/annotations
    - DELETE /api/v1/ide/annotations/:id
    - GET  /api/v1/ide/regions
    - GET  /api/v1/ide/events
    - GET  /api/v1/ide/presence
    - GET  /api/v1/ide/presence/stream
    - GET  /api/v1/ide/cursors
    - POST /api/v1/ide/cursors
    - GET  /api/v1/ide/cursors/stream

    All routes use the workspace base resolution from
    {!Server_routes_http_routes_workspace} so the IDE reads/writes
    from the correct project or keeper playground. *)

module Http = Http_server_eio

val add_routes : Http.Router.t -> Http.Router.t

module For_testing : sig
  val bind_mutation_keeper_id :
    auth_identity:string -> requested:string option -> (string, string) result
  (** task-1736 B3 — resolve the acting keeper_id for an annotation
      mutation. Returns the [auth_identity] when [requested] is absent,
      blank, or equal; returns [Error] when [requested] names a
      different keeper (rejected as impersonation). *)

  val parse_annotation_kind :
    string option -> (Ide_annotation_types.annotation_kind, string) result
  (** Parses the optional request [kind] field. Missing kind preserves the
      historical [Comment] default; unknown explicit values are rejected
      rather than coerced. *)
end
