(** Keeper turn-lane telemetry and backlog task reconciliation. *)

(** Per-turn lane classification.  Closed sum type; the OCaml side
    pins the alphabet emitted by keeper_run_tools
    ({"text_only", "tool_optional", "tool_disabled", "retry"}).
    Plain to_string/of_string keeps this module from exposing
    additional spec catalog bindings. *)
type turn_lane =
  | Lane_pre_dispatch
      (** Pre-turn placeholder before [compute_tool_surface] runs.
          Emitted only by [keeper_turn_helpers.pre_dispatch_tool_surface];
          never produced by the per-turn lane logic at
          keeper_run_tools.ml:963-973. *)
  | Lane_text_only
  | Lane_tool_optional
  | Lane_tool_disabled
  | Lane_retry

val turn_lane_to_string : turn_lane -> string
val turn_lane_of_string : string -> turn_lane option
val turn_lane_to_yojson : turn_lane -> Yojson.Safe.t

(** Diagnostic surface metrics emitted into trajectory entries. *)
type tool_surface_metrics =
  { turn_lane : turn_lane
  ; config_root : string
  ; runtime_config_path : string option
  }

(** Find the active task ID a keeper currently owns. *)
val owned_active_task_id_for_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_id.Task_id.t option

(** Field-level merge for [write_meta_with_merge]. *)
val merge_current_task_id :
  latest:Keeper_meta_contract.keeper_meta ->
  caller:Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta

(** Reconcile [meta.current_task_id] with the backlog. *)
val sync_current_task_id_from_backlog :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta

(** Best-effort reconciliation for callers that only know an agent name.
    No-ops for non-keeper agents. *)
val sync_current_task_id_for_agent_name :
  config:Workspace.config ->
  agent_name:string ->
  unit

(** Convenience [List.map Keeper_tool_name.to_string]. *)
val tool_names : Keeper_tool_name.t list -> string list
