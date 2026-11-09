(** Token-bound Admin reads of direct Core execution history. *)
type route
val route : string -> route option
val permission : Masc_domain.permission
val handle_get : Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> route -> unit

val event_json : redact_json:(Yojson.Safe.t -> Yojson.Safe.t) ->
  Agent_core.Agent.Execution_projection.event -> Yojson.Safe.t
(** Dashboard presentation of canonical events. All event/run/node/parent/cause
    identities are preserved; content is redacted separately. Update bodies
    are limited to output/tool snapshots and deltas. Checkpoints and provider
    request/response bodies remain behind their dedicated inspection APIs. *)
