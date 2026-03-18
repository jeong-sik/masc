(** Keeper Autonomy — Karpathy Autonomy Slider for Keeper agents.

    Defines 5 levels of autonomy (L1-L5) that control how independently
    a keeper acts. Connects to goal_store for goal-driven behavior and
    eval_gate for safety checks.

    @since 2.74.0 *)

(** Autonomy levels from fully reactive to fully independent. *)
type autonomy_level =
  | L1_Reactive     (** Respond to messages only. No self-initiated action. *)
  | L2_Suggestive   (** Generate suggestions, post to board. No auto-execution. *)
  | L3_Guided       (** Auto-execute safe actions. Dangerous ones need approval. *)
  | L4_Autonomous   (** Auto-execute most actions. Periodic reports only. *)
  | L5_Independent  (** Full autonomy. Intervene only on critical failures. *)

(** Proposed action for a keeper to take toward a goal. *)
type proposed_action = {
  goal_id : string;
  goal_title : string;
  action_description : string;
  risk_level : [`Safe | `Moderate | `Dangerous];
  estimated_cost_usd : float;
}

(** Request to start a perpetual agent for long-horizon goals. *)
type perpetual_agent_request = {
  goal_id : string;
  goal_title : string;
  models : string list;
  coding_mode : bool;
  coding_agent : string;
}

(** Result of evaluating next action for a keeper. *)
type next_action =
  | NoGoals
  | NoActionNeeded
  | Propose of proposed_action
  | Skip of string  (** reason for skipping *)
  | StartPerpetualAgent of perpetual_agent_request

val perpetual_agent_request_to_json : perpetual_agent_request -> Yojson.Safe.t
val autonomy_level_to_string : autonomy_level -> string
val autonomy_level_of_string : string -> autonomy_level option
val autonomy_level_to_int : autonomy_level -> int
val risk_level_to_string : [`Safe | `Moderate | `Dangerous] -> string
val proposed_action_to_json : proposed_action -> Yojson.Safe.t
val next_action_to_json : next_action -> Yojson.Safe.t

(** Evaluate what action a keeper should take next, given its active goals. *)
val evaluate_next_action :
  config:Room.config ->
  goal_ids:string list ->
  keeper_name:string ->
  next_action

(** Determine whether an action should auto-execute based on autonomy level. *)
val should_auto_execute :
  autonomy_level:autonomy_level ->
  proposed_action ->
  bool

(** Generate a concrete action plan using LLM, given a goal.
    Routes through Llm_cascade "keeper_autonomy" profile. *)
val generate_action_plan :
  goal:Goal_store.goal ->
  keeper_context:string ->
  (string, string) result
