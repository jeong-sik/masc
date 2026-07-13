(** Keeper turn-lane telemetry and backlog task reconciliation. *)

(* Closed sum type for turn_lane.  Two producers emit values:
   - keeper_run_tools.ml emits the per-turn lanes
     (text_only, tool_optional, tool_disabled, retry).
   - keeper_turn_helpers.pre_dispatch_tool_surface emits the
     [Lane_pre_dispatch] placeholder before the per-turn lane logic
     runs.
   No [@@deriving tla] because this is a small runtime-local lane
   label, not a spec catalog. *)
type turn_lane =
  | Lane_pre_dispatch
  | Lane_text_only
  | Lane_tool_optional
  | Lane_tool_disabled
  | Lane_retry

let turn_lane_to_string = function
  | Lane_pre_dispatch -> "pre_dispatch"
  | Lane_text_only -> "text_only"
  | Lane_tool_optional -> "tool_optional"
  | Lane_tool_disabled -> "tool_disabled"
  | Lane_retry -> "retry"

let turn_lane_of_string = function
  | "pre_dispatch" -> Some Lane_pre_dispatch
  | "text_only" -> Some Lane_text_only
  | "tool_optional" -> Some Lane_tool_optional
  | "tool_disabled" -> Some Lane_tool_disabled
  | "retry" -> Some Lane_retry
  | _ -> None

let turn_lane_to_yojson lane = `String (turn_lane_to_string lane)

type tool_surface_metrics =
  { turn_lane : turn_lane
  ; config_root : string
  ; runtime_config_path : string option
  }

let owned_active_task_id_for_meta =
  Keeper_current_task_reconcile.owned_active_task_id_for_meta

let merge_current_task_id =
  Keeper_current_task_reconcile.merge_current_task_id

let sync_current_task_id_from_backlog =
  Keeper_current_task_reconcile.sync_current_task_id_from_backlog

let sync_current_task_id_for_agent_name =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name

let tool_names =
  List.map Keeper_tool_name.to_string
