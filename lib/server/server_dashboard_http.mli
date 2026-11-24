(** Server_dashboard_http — Dashboard HTTP handlers (facade).

    Runtime-includes 5 sub-modules so callers reach the
    dashboard surface through a single namespace:
    - {!Server_dashboard_http_core}
    - {!Server_dashboard_http_runtime_info}
    - {!Server_dashboard_http_execution_surfaces}
    - {!Server_dashboard_http_namespace_truth}

    Plus 21 own helpers + 1 type — board / memory /
    Gate / verification / planning / goals /
    keeper composite / fleet composite / operator
    action+confirm HTTP route entries.

    Reached via [open Server_dashboard_http] in 2
    routing modules (server_routes_http_routes_dashboard,
    server_h2_gateway), via dotted call from
    server_runtime_bootstrap, and via the
    [module SDH = Masc.Server_dashboard_http] alias
    in [test/test_hitl_approval]. *)

include module type of struct
  include Server_dashboard_http_core
end

include module type of struct
  include Server_dashboard_http_runtime_info
end

include module type of struct
  include Server_dashboard_http_execution_surfaces
end

include module type of struct
  include Server_dashboard_http_namespace_truth
end

(** {1 Approval-resolve HTTP error} *)

type approval_resolve_http_error =
  | Bad_request of string
  | Gone of Keeper_approval_queue.resolve_error
  | Unavailable of Keeper_approval_queue.resolve_error

val approval_resolve_http_error_to_string :
  approval_resolve_http_error -> string

(** {1 Board / memory / Gate HTTP entries} *)

val dashboard_memory_http_payload :
  ?config:Workspace.config -> reader:Masc_board_handlers.Board_access.reader -> actor:string option ->
  Httpun.Request.t -> Dashboard_cache.cached_payload

val board_memory_cache_key :
  reader:Masc_board_handlers.Board_access.reader ->
  base_path:string option ->
  hearth:string option ->
  author_filter:string option ->
  text_query:string option ->
  sort_by:Board_dispatch.sort_order ->
  exclude_system:bool ->
  exclude_automation:bool ->
  limit:int ->
  offset:int ->
  voter:string option ->
  string
(** The cache key of the Board list read that {!dashboard_memory_http_payload}
    answers with these values, after its bounds and trims. Reads that differ
    in any part have different keys: a part taken from the request is written
    with its length, so it cannot read as the part after it. *)

val dashboard_gate_http_json :
  Httpun.Request.t -> base_path:string -> Yojson.Safe.t

val invalidate_gate_snapshots : base_path:string -> unit
(** Drop every cached Gate snapshot of [base_path], whatever its limit,
    window and queue revision. *)

val dashboard_gate_tool_events_http_json :
  Httpun.Request.t -> base_path:string -> Yojson.Safe.t

val dashboard_scheduled_automation_http_json :
  config:Workspace.config -> Yojson.Safe.t
(** The fleet list of the schedule projection, cached and offloaded: the
    answer to [GET /api/v1/dashboard/scheduled-automation] with no selector.
    The route calls {!dashboard_scheduled_automation_query_http_json}, which
    delegates here. *)

val dashboard_scheduled_automation_query_http_json :
  config:Workspace.config -> Httpun.Request.t -> Yojson.Safe.t
(** Query-aware owner for the scheduled-automation route. With no selector it
    delegates to {!dashboard_scheduled_automation_http_json}.
    [active_only=true] answers the active-only list, cached the same way. A
    [payload_target], a [cursor] and an exact [schedule_id] lookup read the
    schedule store without populating a client-controlled cache key. *)

val dashboard_gate_resolve_http_json :
  ?workspace_config:Workspace.config ->
  base_path:string ->
  created_by:string ->
  args:Yojson.Safe.t ->
  unit ->
  (Yojson.Safe.t, approval_resolve_http_error) result

val dashboard_gate_retry_http_json :
  workspace_config:Workspace.config ->
  base_path:string ->
  requested_by:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val dashboard_gate_rule_delete_http_json :
  base_path:string ->
  deleted_by:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val dashboard_schedule_prune_http_json :
  config:Workspace_utils.config ->
  operator_name:string ->
  (Yojson.Safe.t, string) result

(** {1 Verification + planning + goals} *)

val dashboard_planning_http_json :
  config:Workspace.config -> Yojson.Safe.t

val planning_cache_key : base_path:string -> string
val cached_planning_payload :
  config:Workspace.config -> Dashboard_cache.cached_payload
(** Read the cached planning projection. *)

val install_goal_projection_observer : unit -> unit
(** After Goal rows, audit events, the verification ledger or the measurement
    store commit: drop the workspace's planning projection, then announce
    {!Goal_projection_broadcast.changed_event} to its observers. *)

val dashboard_goals_tree_http_json :
  config:Workspace.config -> Yojson.Safe.t

val direct_goals_tree_payload : scope:Mcp_server.workspace_scope -> accept_encoding:string option ->
  (Yojson.Safe.t * string * (string * string) list, Yojson.Safe.t) result
(** Generate, serialize and encode a fresh Goal tree on the CPU pool. Concurrent
    callers share only work that starts after they arrive. This is not an
    atomic snapshot across stores. *)
val goal_tree_scope_current : Mcp_server.server_state -> Mcp_server.workspace_scope -> bool

val goal_cache_scope : config:Workspace.config -> string
(** Cache scope including the current canonical Goal store root. *)

val cached_goals_tree_payload :
  config:Workspace.config -> Dashboard_cache.cached_payload
(** The goals tree as a cached read. Its key names the goal projection
    generation; when the current generation has no entry yet, the tree of the
    highest generation this function filled for the workspace answers at once
    and the new one is computed in the background. *)

val dashboard_goal_detail_http_json :
  config:Workspace.config -> goal_id:string -> Yojson.Safe.t

(** {1 Keeper / fleet composite} *)

val dashboard_keeper_composite_json :
  config:Workspace.config ->
  Keeper_registry.registry_entry ->
  Yojson.Safe.t

val dashboard_fleet_composite_json :
  config:Workspace.config -> unit -> Yojson.Safe.t

(** {1 Operator action / confirm} *)

val operator_action_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  authorized_actor:string ->
  Httpun.Request.t ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val operator_action_for_actor_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  actor:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Actor-bound variant for routes whose caller identity was already
    authenticated by {!Auth_gate.decide} (multi-account browser sessions),
    avoiding single-user [Server_auth] header/token probing. *)

val operator_confirm_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  authorized_actor:string ->
  Httpun.Request.t ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val operator_confirm_for_actor_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  actor:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Actor-bound counterpart of {!operator_confirm_http_json} for
    {!Auth_gate}-authenticated callers. *)

val operator_error_json : string -> Yojson.Safe.t

(** {1 Cold-start bootstrap aggregator}

    Returns the snapshot of multiple dashboard slices in a single JSON
    payload so the frontend cold start does not fan out into N
    parallel HTTP calls.  Per-slice exceptions are captured and
    surfaced as a JSON object under the slice key:
    {"error":"slice_unavailable", "slice":"<name>"}.  A single
    broken slice therefore does not 500 the whole bootstrap.

    Single SSOT — both the HTTP/1.1 router and the HTTP/2 gateway
    call this function so the payload shape and slice list cannot
    drift between transports. *)
val dashboard_bootstrap_http_json :
  ?include_request_auth:bool ->
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t

(** {1 Multi-Core Dashboard Pre-warming} *)

val warm_dashboard_surfaces : Mcp_server.server_state -> unit
(** Concurrently pre-warms primary dashboard surfaces (shell, board,
    planning, config, keeper-memory-health, task-history) across worker
    domains using the multi-core domain pool so initial requests hit warm
    caches instantly. *)
