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
  config:Workspace.config ->
  (config:Workspace.config -> sw:Eio.Switch.t -> 'a) ->
  'a

(** Internal cached surfaces for proactive refresh loops.
    Exposed for the facade module [Server_dashboard_http]. *)
val operator_snapshot_cache : cached_surface
val operator_digest_cache : cached_surface
val shell_warmed : bool Atomic.t
val shell_warming : bool Atomic.t
val last_good_shell : Yojson.Safe.t Atomic.t
val last_good_shell_light : Yojson.Safe.t Atomic.t

(** Late-bound broadcast callbacks — set by [Server_dashboard_http]
    after [Sse] module is in scope. *)
val operator_snapshot_broadcast_ref : (Yojson.Safe.t -> unit) ref
val operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref
val mission_cache : cached_surface

(** {1 Dashboard Timeout} *)

val with_dashboard_timeout :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  (unit -> Yojson.Safe.t) ->
  Yojson.Safe.t

(** {1 Cache Key Helpers} *)

val dashboard_cache_key : Workspace.config -> string -> string -> string

(** {1 Projection Diagnostics} *)

val with_projection_diagnostics :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t

(** {1 Sanitization and Request Helpers} *)

val dashboard_shell_with_request_auth_json :
  request:Httpun.Request.t ->
  Workspace.config ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** Inject the request-bound dashboard auth contract into a shell payload.
    Snapshot shell payloads are process-wide and deliberately omit
    per-request auth; HTTP handlers must add it back before responding. *)

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

val dashboard_briefing_http_json :
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

val dashboard_briefing_sections_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

(** {1 Shell and Data Helpers} *)

val dashboard_shell_status_json : Workspace.config -> Yojson.Safe.t
val dashboard_task_json : Workspace.config -> Masc_domain.task -> Yojson.Safe.t
val dashboard_agent_json : Masc_domain.agent -> Yojson.Safe.t
val dashboard_message_json : Masc_domain.message -> Yojson.Safe.t
(* dashboard_current_workspace_id removed — namespace retired (#unify-namespace). *)
val dashboard_tasks_safe : Workspace.config -> Masc_domain.task list
val dashboard_agents_safe : Workspace.config -> Masc_domain.agent list
val dashboard_messages_safe :
  Workspace.config -> since_seq:int -> limit:int -> Masc_domain.message list
val provider_capacity_json : unit -> Yojson.Safe.t
val dashboard_shell_http_json :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?request:Httpun.Request.t ->
  ?timing:Server_timing.t ->
  ?light:bool ->
  Workspace.config ->
  Yojson.Safe.t

val dashboard_shell_cache_key :
  ?light:bool ->
  Workspace.config ->
  string

val dashboard_shell_cache_prefix : Workspace.config -> string

val dashboard_shell_payload_json :
  ?timing:Server_timing.t ->
  ?light:bool ->
  Workspace.config -> Yojson.Safe.t

val is_dashboard_cache_timeout_json :
  Yojson.Safe.t -> bool
