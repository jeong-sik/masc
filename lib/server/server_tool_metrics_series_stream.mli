(** A mounted series query receives its full snapshot on initial read,
    committed metric invalidation, and the exact next row/bucket deadline.
    The stream owns its subscription and timer; closing it retains neither.
    No background query registry or healthy HTTP refresh cadence exists. *)

val stream_path : string

type snapshot = {
  json : Yojson.Safe.t;
  next_change_at : float;
}

val read_snapshot :
  config:Masc.Workspace.config ->
  request:Server_dashboard_http_agent_api.tool_series_request ->
  now:float -> (snapshot, string) result
(** Uses the same query/window and wire projection as the REST series route.
    Runs synchronously; production callers submit it as CPU pool work. *)

val is_invalidation : Masc.Sse.external_event -> bool
(** Pure recognition of the typed, workspace-admitted metric invalidation.
    Runtime authority filtering belongs to {!Masc.Sse.subscribe_external}. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Requires the original observation's [Sse_wire.instance_header]. Success
    attests that exact instance; workspace replacement retires the query. *)
