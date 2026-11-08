(** Keeper turn-lane telemetry and backlog task reconciliation. *)

(** Per-turn lane classification.  Closed sum type; the OCaml side
    pins the alphabet emitted by keeper_run_tools
    ({"text_only", "tool_optional", "tool_disabled"}).
    Plain to_string/of_string keeps this module from exposing
    additional spec catalog bindings. *)
type turn_lane =
  | Lane_pre_dispatch
      (** Pre-turn placeholder before [compute_tool_surface] runs.
          Emitted only by [keeper_turn_helpers.pre_dispatch_tool_surface];
          never produced by the per-turn lane logic in [compute_tool_surface]
          (keeper_run_tools_setup.ml). *)
  | Lane_text_only
  | Lane_tool_optional
  | Lane_tool_disabled

val turn_lane_to_string : turn_lane -> string
val turn_lane_to_yojson : turn_lane -> Yojson.Safe.t

(** Diagnostic surface metrics emitted into trajectory entries. *)
type tool_surface_metrics =
  { turn_lane : turn_lane
  ; config_root : string
  ; runtime_config_path : string option
  }

(** The tool surface a request actually carried, rather than the one the turn
    was built with.

    Two things separate them. The Agent Core lane is handed a listing in place
    of the attached-service schemas, and that lane widens its own set mid-turn
    when the model loads one — so from the round after a load the built list is
    short by exactly the tools the model just asked for.

    This accessor is for callers that already know they are in the Agent Core
    lane. The cell can survive failover to an official client; mixed-runtime
    callers must use [for_attempt] with the current checkpoint owner. *)
val on_the_wire :
  agent_cell:Agent_core.Agent.t option ref ->
  built:Agent_core.Tool.t list ->
  Agent_core.Tool.t list

type attempt_surface =
  { tools : Agent_core.Tool.t list
  ; loader_alive : bool
  }

val for_attempt :
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
  agent_cell:Agent_core.Agent.t option ref ->
  built:Agent_core.Tool.t list ->
  attempt_surface
(** Only the current Agent Core attempt may use the cell's live tools and
    deferred loader. Official clients and pre-dispatch callers use the built
    surface without a loader, even when an earlier attempt left an agent. *)

val for_request :
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
  enabled:bool ->
  tool_choice:Agent_core.Types.tool_choice option ->
  schema_names:string list ->
  agent_cell:Agent_core.Agent.t option ref ->
  built:Agent_core.Tool.t list ->
  Agent_core.Tool.t list
(** Callable schemas for request-bound context references. Applies the active
    surface switch, explicit no-tools choice and final schema filter to the
    current attempt's live agent/official-client surface. *)
