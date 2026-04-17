(** Server_dashboard_http_core — Dashboard HTTP handlers and background refresh loops.

    Includes cache management, executor pool offloading, batch API, operator
    snapshot/digest, mission, and shell dashboard endpoints.

    Re-exports from [Server_dashboard_http_cache], [Dashboard_http_helpers],
    [Dashboard_http_monitoring], and [Dashboard_http_keeper]. *)

(** {1 Re-exported sub-modules} *)

include module type of Server_dashboard_http_cache
include module type of Dashboard_http_helpers
include module type of Dashboard_http_monitoring
include module type of Dashboard_http_keeper

(** {1 Executor Pool} *)

type dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

val set_executor_pool : Eio.Executor_pool.t -> unit

val run_dashboard_compute :
  ?mode:dashboard_compute_mode ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Coord.config ->
  (config:Coord.config -> sw:Eio.Switch.t -> 'a) ->
  'a

(** Internal cached surfaces for proactive refresh loops.
    Exposed for the facade module [Server_dashboard_http]. *)
val _operator_snapshot_cache : cached_surface
val _operator_digest_cache : cached_surface
val _shell_warmed : bool Atomic.t
val _shell_warming : bool Atomic.t
val _last_good_shell : Yojson.Safe.t Atomic.t

(** Late-bound broadcast callbacks — set by [Server_dashboard_http]
    after [Sse] module is in scope. *)
val _operator_snapshot_broadcast_ref : (Yojson.Safe.t -> unit) ref
val _operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref
val _mission_cache : cached_surface

(** {1 Dashboard Timeout} *)

val with_dashboard_timeout :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  (unit -> Yojson.Safe.t) ->
  Yojson.Safe.t

(** {1 Cache Key Helpers} *)

val room_scoped_cache_key : Coord.config -> string -> string -> string

(** {1 Projection Diagnostics} *)

val with_projection_diagnostics :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t

(** {1 Sanitization and Request Helpers} *)

val operator_actor_hint : Httpun.Request.t -> string option

(** {1 Batch API} *)

val dashboard_batch_json :
  ?compact:bool -> Coord.config -> Yojson.Safe.t

(** {1 Operator Snapshot/Digest} *)

val start_operator_snapshot_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit

val start_operator_digest_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit

val operator_snapshot_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

val operator_digest_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  (Yojson.Safe.t, 'a) result

(** {1 Mission} *)

val start_mission_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit

val dashboard_mission_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

val dashboard_session_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

val dashboard_mission_briefing_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

(** {1 Shell and Data Helpers} *)

val dashboard_shell_status_json : Coord.config -> Yojson.Safe.t
val dashboard_task_json : Coord.config -> Types.task -> Yojson.Safe.t
val dashboard_agent_json : Types.agent -> Yojson.Safe.t
val dashboard_message_json : Types.message -> Yojson.Safe.t
(* dashboard_current_room_id removed — namespace retired (#unify-namespace). *)
val dashboard_tasks_safe : Coord.config -> Types.task list
val dashboard_agents_safe : Coord.config -> Types.agent list
val dashboard_messages_safe :
  Coord.config -> since_seq:int -> limit:int -> Types.message list
val provider_capacity_json : unit -> Yojson.Safe.t
val dashboard_shell_http_json :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?request:Httpun.Request.t ->
  Coord.config ->
  Yojson.Safe.t

val dashboard_shell_payload_json :
  Coord.config -> Yojson.Safe.t

val is_dashboard_cache_timeout_json :
  Yojson.Safe.t -> bool
