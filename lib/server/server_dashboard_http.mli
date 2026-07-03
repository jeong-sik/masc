(** Server_dashboard_http — Dashboard HTTP handlers (facade).

    Runtime-includes 5 sub-modules so callers reach the
    dashboard surface through a single namespace:
    - {!Server_dashboard_http_core}
    - {!Server_dashboard_http_runtime_info}
    - {!Server_dashboard_http_execution_surfaces}
    - {!Server_dashboard_http_namespace_truth}
    - {!Server_dashboard_http_memory_subsystems}

    Plus 21 own helpers + 1 type — board / memory /
    governance / verification / planning / goals /
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

val approval_resolve_http_error_to_string :
  approval_resolve_http_error -> string

val approval_resolve_decision_required_message : string

(** {1 Board / memory / governance HTTP entries} *)

val dashboard_board_json :
  ?config:Workspace.config ->
  ?hearth:string ->
  ?author_filter:string ->
  ?sort_by:Board_dispatch.sort_order ->
  ?exclude_system:bool ->
  ?exclude_automation:bool ->
  ?limit:int ->
  ?offset:int ->
  ?voter:string ->
  ?blind_votes:bool ->
  unit ->
  Yojson.Safe.t

val dashboard_memory_http_json :
  ?config:Workspace.config -> Httpun.Request.t -> Yojson.Safe.t

val dashboard_memory_subsystems_include_entries :
  Httpun.Request.t -> bool

val dashboard_memory_subsystems_http_json :
  config:Workspace_utils.config ->
  ?include_memory_entries:bool ->
  Httpun.Request.t ->
  Yojson.Safe.t

val dashboard_governance_http_json :
  Httpun.Request.t -> base_path:string -> Yojson.Safe.t

val dashboard_governance_tool_events_http_json :
  Httpun.Request.t -> Yojson.Safe.t

val dashboard_proof_http_json :
  config:Workspace.config -> Httpun.Request.t -> Yojson.Safe.t

val dashboard_governance_approval_resolve_http_json :
  base_path:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, approval_resolve_http_error) result

val dashboard_governance_approval_rule_delete_http_json :
  base_path:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val dashboard_schedule_resolve_http_json :
  config:Workspace_utils.config ->
  operator_name:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

(** {1 Verification + planning + goals} *)

val dashboard_verification_resolve_http_json :
  config:Workspace.config ->
  verifier:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val dashboard_planning_http_json :
  config:Workspace.config -> Yojson.Safe.t

val dashboard_goals_tree_http_json :
  config:Workspace.config -> Yojson.Safe.t

val dashboard_goals_snapshot_json :
  config:Workspace.config -> Yojson.Safe.t

val dashboard_ide_snapshot_json :
  config:Workspace.config -> Yojson.Safe.t

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
  Httpun.Request.t ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val operator_confirm_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

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
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
