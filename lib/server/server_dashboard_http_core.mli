(** Server_dashboard_http_core — Dashboard HTTP handlers and background refresh loops.

    Includes cache management, executor pool offloading, batch API, operator
    snapshot/digest, mission, and shell dashboard endpoints.

    Re-exports from [Server_dashboard_http_cache], [Dashboard_http_helpers],
    and [Dashboard_http_keeper]. *)

(** {1 Re-exported sub-modules} *)

include module type of struct include Server_dashboard_http_cache end
include module type of Dashboard_http_helpers
include module type of Dashboard_http_keeper

(** {1 Executor Pool} *)

type dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

val run_dashboard_compute :
  ?mode:dashboard_compute_mode ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  kind:Pool_work.kind ->
  name:string ->
  (config:Workspace.config -> sw:Eio.Switch.t -> 'a) ->
  'a

(** Internal cached surfaces for proactive refresh loops.
    Exposed for the facade module [Server_dashboard_http]. *)
val shell_warmed : bool Atomic.t
val shell_warming : bool Atomic.t
val last_good_shell : Yojson.Safe.t Atomic.t
val last_good_shell_light : Yojson.Safe.t Atomic.t

(** Captured-scope Mission read cache. *)
val mission_cache : state:Mcp_server.server_state -> cached_surface

(** {1 Dashboard Timeout} *)

val with_dashboard_timeout :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  (unit -> Yojson.Safe.t) ->
  Yojson.Safe.t

(** {1 Cache Key Helpers} *)

val dashboard_cache_key : Workspace.config -> string -> string -> string

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
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  unit

val start_operator_digest_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  unit

val operator_snapshot_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

val operator_snapshot_for_actor_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  actor:string ->
  Httpun.Request.t ->
  Yojson.Safe.t

val operator_digest_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  (Yojson.Safe.t, 'a) result

val operator_digest_for_actor_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  actor:string ->
  Httpun.Request.t ->
  (Yojson.Safe.t, 'a) result

(** {1 Mission} *)

val start_mission_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  unit

type mission_http_request
val mission_http_request : state:Mcp_server.server_state -> Httpun.Request.t -> mission_http_request
(** Captured at the route entry before executor dispatch. *)
val dashboard_briefing_for_request :
  sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mission_http_request -> Yojson.Safe.t
val dashboard_health_line_for_request :
  sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mission_http_request -> Yojson.Safe.t

val dashboard_briefing_sections_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

(** {1 Shell and Data Helpers} *)

val dashboard_shell_status_json : Workspace.config -> Yojson.Safe.t
val dashboard_tasks_safe : Workspace.config -> Masc_domain.task list
val dashboard_agents_safe : Workspace.config -> Masc_domain.agent list
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

val tasks_24h_rollup_json :
  now:float -> Masc_domain.task list -> Yojson.Safe.t
(** O(N) rollup of already-loaded tasks: [tasks_done_24h], [tasks_done_total],
    [tasks_in_progress], [tasks_claimed], [tasks_awaiting_verification],
    [tasks_todo], and [tasks_cancelled]. *)

val verifications_24h_of_runs :
  now:float -> Verification_run_registry.run list -> (int * int) option
(** Count completed [Approved] and [Rejected] verification runs within the
    trailing 24h window. Returns [None] when [runs] is empty (unobserved) so
    callers never fabricate zero counts. *)

val keeper_groups_json : (string * string option) list -> Yojson.Safe.t
(** Deployment-neutral grouping of configured keepers by their optional
    [keeper.group] TOML field (trimmed; absent or blank maps to
    ["ungrouped"]). Named groups are sorted alphabetically with ["ungrouped"]
    last, and keepers within each group are sorted alphabetically. *)
