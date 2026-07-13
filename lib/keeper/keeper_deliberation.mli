(** Keeper_deliberation — typed action space, world observation, and
    MODEL-driven deliberation.

    @since 2.90.0 *)

(** {1 Triggers} *)

type deliberation_trigger =
  | DirectMention
  | NewUnclaimedTask
  | FailedTask
  | KeeperFiberStartedOrStopped
  | GoalDeadline
  | BoardActivity of string
  | IdleTimeout
  | MetricsAnomaly of string
  | StrategicReview
  | SelfDirectedExplore

val deliberation_trigger_to_string : deliberation_trigger -> string
val deliberation_trigger_to_json : deliberation_trigger -> Yojson.Safe.t

(** {1 Actions} *)

type deliberation_action =
  | Noop of string
  | BoardPost of { content: string; hearth: string option }
  | BoardComment of { post_id: string; content: string }
  | BoardVote of { post_id: string; direction: string }
  | TaskClaim of { task_id: string; reason: string }
  | TaskCreate of { title: string; description: string; priority: int option }
  | Broadcast of { message: string }
  | ProposeSpawn of { topic: string; reason: string }
  | MultiStep of deliberation_action list

val deliberation_action_to_string : deliberation_action -> string

(** Map typed action to stable policy labels for policy logging. *)
val deliberation_action_to_policy_label : deliberation_action -> string

val deliberation_action_to_json : deliberation_action -> Yojson.Safe.t

(** Structured deliberation result returned by the model boundary. *)
type structured_result = {
  action: deliberation_action;
  reasoning: string;
  confidence: float;
}

val structured_result_schema : structured_result Agent_sdk.Structured.schema

(** {1 World observation} *)

type world_observation = {
  keeper_name: string;
  direct_mention: bool;
  has_question: bool;
  message_content: string;
  unclaimed_task_count: int;
  failed_task_count: int;
  running_keeper_fiber_count: int;
  keeper_fiber_count_changed: bool;
  active_goal_count: int;
  idle_seconds: int;
  board_new_post_count: int;
  board_mention_count: int;
}

val empty_world_observation : keeper_name:string -> world_observation
val world_observation_to_json : world_observation -> Yojson.Safe.t

(** {1 Deterministic execution} *)

type action_source =
  | Baseline
  | Structured_model
  | Fallback_after_validation_failure

val action_source_to_string : action_source -> string
val action_source_to_json : action_source -> Yojson.Safe.t

type legality_verdict =
  | Legal
  | Illegal of string

type execution_result = {
  proposed_action: deliberation_action;
  selected_action: deliberation_action;
  action_source: action_source;
  fallback_used: bool;
  fallback_reason: string option;
  policy_labels: string list;
  reasoning: string;
  confidence: float;
}

val baseline_execution_result : world_observation -> execution_result
val action_source_of_execution_result : execution_result -> action_source
val execution_result_to_json : execution_result -> Yojson.Safe.t
val policy_labels_of_action : deliberation_action -> string list
val legality_verdict : world_observation -> deliberation_action -> legality_verdict
val execute_structured_result :
  world_observation -> structured_result -> execution_result

(** {1 Triage} *)

type triage_result =
  | Skip of string
  | Triggered of deliberation_trigger list

val triage_result_to_json : triage_result -> Yojson.Safe.t

(** Project objective typed signal labels for the model prompt. Always returns
    [Triggered _], including [Triggered []], so local code never gates the
    configured model call. *)
val triage : world_observation -> triage_result

(** {1 Deliberation meta (tracking fields for keeper_meta)} *)

type deliberation_meta = {
  deliberation_count: int;
  deliberation_cost_total_usd: float;
  last_deliberation_ts: float;
  last_triage_triggers: string;
}

val default_deliberation_meta : deliberation_meta
val deliberation_meta_to_json : deliberation_meta -> (string * Yojson.Safe.t) list
val deliberation_meta_of_json : Yojson.Safe.t -> deliberation_meta

(** {1 Baseline action} *)

(** Deterministic baseline using the typed action space. *)
val deterministic_baseline_action : world_observation -> deliberation_action

(** {1 Phase 2: Deliberation Evaluation} *)

(** Current daily budget from keeper runtime config
    ([MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD], default: 0.10). *)
val daily_budget_usd : unit -> float

(** Advisory cost telemetry for deliberation.

    Always returns [true]; daily cost thresholds must not gate deliberation. *)
val deliberation_budget_check :
  daily_budget_usd:float -> cost_today_usd:float -> bool

(** Build a prompt for the MODEL to decide the keeper's next action.
    Describes the keeper's identity, current state, detected triggers,
    and available actions. Asks the MODEL to return only the schema-matching
    tool input object. *)
val build_deliberation_prompt :
  keeper_name:string ->
  goal:string ->
  triggers:deliberation_trigger list ->
  world_observation ->
  string

(** Parse a strict JSON tool-input object into a typed deliberation action.
    Returns [(action, reasoning, confidence)] or an [Error] message.
    This parser does not recover fenced or embedded JSON from free-form text. *)
val parse_deliberation_response :
  string -> (deliberation_action * string * float, string) result
