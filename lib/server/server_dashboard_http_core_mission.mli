type request

val request : state:Mcp_server.server_state -> Httpun.Request.t -> request
(** Capture scope, default owner and actor at the admitted route boundary,
    before dispatching CPU/I/O work. Never re-resolve scope after a yield. *)

val cache : state:Mcp_server.server_state -> Server_dashboard_http_cache.cached_surface

val start :
  state:Mcp_server.server_state -> sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t -> unit
(** Initial/current source reads and actual semantic deadlines, plus the
    existing 120-second failure retry. Healthy idle has no refresh timer.
    Default HTTP fills share the owner; actor responses remain request-local.
    Canonical completion publishes immutable mission_snapshot directly. *)

val json : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> request -> Yojson.Safe.t
(** The owner is the HTTP cache. A caller must not put another time-only route
    cache around this function. Parameterized keys include captured instance
    and source admission; they cannot seed the default canonical owner. Such
    actor-local responses carry only the captured [observer_instance_id], not
    canonical Mission generation/sequence/state metadata. *)

val health_line : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> request -> Yojson.Safe.t
(** Derive the existing Home Health contract from the same captured default
    Mission owner and retain its [observer_instance_id]. Request actor does
    not change this workspace line. *)
