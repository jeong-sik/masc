(** Keeper_deliberation_types — type definitions, serialization, and pure
    observation predicates extracted from [Keeper_deliberation] (759 LoC).
    @since Keeper 500-line decomposition *)

(* ---------- Deliberation trigger: why the keeper might act ---------- *)

type deliberation_trigger =
  | DirectMention
  | NewUnclaimedTask
  | FailedTask
  | AgentJoinedOrLeft
  | GoalDeadline
  | BoardActivity of string
  | IdleTimeout
  | MetricsAnomaly of string
  | StrategicReview
  | SelfDirectedExplore

let deliberation_trigger_to_string = function
  | DirectMention -> "direct_mention"
  | NewUnclaimedTask -> "new_unclaimed_task"
  | FailedTask -> "failed_task"
  | AgentJoinedOrLeft -> "agent_joined_or_left"
  | GoalDeadline -> "goal_deadline"
  | BoardActivity detail -> "board_activity:" ^ detail
  | IdleTimeout -> "idle_timeout"
  | MetricsAnomaly detail -> "metrics_anomaly:" ^ detail
  | StrategicReview -> "strategic_review"
  | SelfDirectedExplore -> "self_directed_explore"

let deliberation_trigger_to_json trigger =
  `String (deliberation_trigger_to_string trigger)

(* ---------- Deliberation action: what the keeper can do ---------- *)

type deliberation_action =
  | Noop of string
  | ReplyInRoom of { room_id: string; content: string }
  | BoardPost of { content: string; hearth: string option }
  | BoardComment of { post_id: string; content: string }
  | BoardVote of { post_id: string; direction: string }
  | TaskClaim of { task_id: string; reason: string }
  | Broadcast of { message: string }
  | ProposeSpawn of { topic: string; reason: string }
  | StartDiscussion of { topic: string; context: string }
  | ShareFinding of { finding: string; source: string }
  | MultiStep of deliberation_action list

let rec deliberation_action_to_string = function
  | Noop reason -> "noop:" ^ reason
  | ReplyInRoom _ -> "reply_in_room"
  | BoardPost _ -> "board_post"
  | BoardComment _ -> "board_comment"
  | BoardVote _ -> "board_vote"
  | TaskClaim _ -> "task_claim"
  | Broadcast _ -> "broadcast"
  | ProposeSpawn _ -> "propose_spawn"
  | StartDiscussion { topic; _ } -> "start_discussion:" ^ topic
  | ShareFinding { finding; _ } -> "share_finding:" ^ finding
  | MultiStep actions ->
      "multi_step:["
      ^ String.concat "," (List.map deliberation_action_to_string actions)
      ^ "]"

(** Map typed action to stable policy labels used by policy logging and reward models. *)
let deliberation_action_to_policy_label = function
  | Noop _ -> "noop"
  | ReplyInRoom _ -> "reply_in_room"
  | BoardPost _ -> "board_post"
  | BoardComment _ -> "board_comment"
  | BoardVote _ -> "board_vote"
  | TaskClaim _ -> "task_claim"
  | Broadcast _ -> "broadcast"
  | ProposeSpawn _ -> "propose_spawn"
  | StartDiscussion _ -> "start_discussion"
  | ShareFinding _ -> "share_finding"
  | MultiStep _ -> "multi_step"

let rec deliberation_action_to_json = function
  | Noop reason ->
      `Assoc [ ("type", `String "noop"); ("reason", `String reason) ]
  | ReplyInRoom { room_id; content } ->
      `Assoc
        [
          ("type", `String "reply_in_room");
          ("room_id", `String room_id);
          ("content", `String content);
        ]
  | BoardPost { content; hearth } ->
      `Assoc
        [
          ("type", `String "board_post");
          ("content", `String content);
          ( "hearth",
            match hearth with
            | Some h -> `String h
            | None -> `Null );
        ]
  | BoardComment { post_id; content } ->
      `Assoc
        [
          ("type", `String "board_comment");
          ("post_id", `String post_id);
          ("content", `String content);
        ]
  | BoardVote { post_id; direction } ->
      `Assoc
        [
          ("type", `String "board_vote");
          ("post_id", `String post_id);
          ("direction", `String direction);
        ]
  | TaskClaim { task_id; reason } ->
      `Assoc
        [
          ("type", `String "task_claim");
          ("task_id", `String task_id);
          ("reason", `String reason);
        ]
  | Broadcast { message } ->
      `Assoc [ ("type", `String "broadcast"); ("message", `String message) ]
  | ProposeSpawn { topic; reason } ->
      `Assoc
        [
          ("type", `String "propose_spawn");
          ("topic", `String topic);
          ("reason", `String reason);
        ]
  | StartDiscussion { topic; context } ->
      `Assoc
        [
          ("type", `String "start_discussion");
          ("topic", `String topic);
          ("context", `String context);
        ]
  | ShareFinding { finding; source } ->
      `Assoc
        [
          ("type", `String "share_finding");
          ("finding", `String finding);
          ("source", `String source);
        ]
  | MultiStep actions ->
      `Assoc
        [
          ("type", `String "multi_step");
          ("steps", `List (List.map deliberation_action_to_json actions));
        ]

(* ---------- World observation: enriched snapshot for triage ---------- *)

type world_observation = {
  keeper_name: string;
  direct_mention: bool;
  has_question: bool;
  message_content: string;
  unclaimed_task_count: int;
  failed_task_count: int;
  active_agent_count: int;
  agent_count_changed: bool;
  active_goal_count: int;
  idle_seconds: int;
  idle_gate: int;
  board_new_post_count: int;
  board_mention_count: int;
}

let empty_world_observation ~keeper_name =
  {
    keeper_name;
    direct_mention = false;
    has_question = false;
    message_content = "";
    unclaimed_task_count = 0;
    failed_task_count = 0;
    active_agent_count = 0;
    agent_count_changed = false;
    active_goal_count = 0;
    idle_seconds = 0;
    idle_gate = 300;
    board_new_post_count = 0;
    board_mention_count = 0;
  }

let world_observation_to_json (obs : world_observation) : Yojson.Safe.t =
  `Assoc
    [
      ("keeper_name", `String obs.keeper_name);
      ("direct_mention", `Bool obs.direct_mention);
      ("has_question", `Bool obs.has_question);
      ("message_content_len", `Int (String.length obs.message_content));
      ("unclaimed_task_count", `Int obs.unclaimed_task_count);
      ("failed_task_count", `Int obs.failed_task_count);
      ("active_agent_count", `Int obs.active_agent_count);
      ("agent_count_changed", `Bool obs.agent_count_changed);
      ("active_goal_count", `Int obs.active_goal_count);
      ("idle_seconds", `Int obs.idle_seconds);
      ("idle_gate", `Int obs.idle_gate);
      ("board_new_post_count", `Int obs.board_new_post_count);
      ("board_mention_count", `Int obs.board_mention_count);
    ]

(* ---------- Triage result ---------- *)

type triage_result =
  | Skip of string
  | Triggered of deliberation_trigger list

let triage_result_to_json = function
  | Skip reason ->
      `Assoc [ ("decision", `String "skip"); ("reason", `String reason) ]
  | Triggered triggers ->
      `Assoc
        [
          ("decision", `String "triggered");
          ( "triggers",
            `List (List.map deliberation_trigger_to_json triggers) );
        ]

(* ---------- Deliberation meta: tracking fields for keeper_meta ---------- *)

type deliberation_meta = {
  deliberation_count: int;
  deliberation_cost_total_usd: float;
  last_deliberation_ts: float;
  last_triage_triggers: string;
}

let default_deliberation_meta =
  {
    deliberation_count = 0;
    deliberation_cost_total_usd = 0.0;
    last_deliberation_ts = 0.0;
    last_triage_triggers = "";
  }

let deliberation_meta_to_json (dm : deliberation_meta) : (string * Yojson.Safe.t) list =
  [
    ("deliberation_count", `Int dm.deliberation_count);
    ("deliberation_cost_total_usd", `Float dm.deliberation_cost_total_usd);
    ("last_deliberation_ts", `Float dm.last_deliberation_ts);
    ("last_triage_triggers", `String dm.last_triage_triggers);
  ]

let deliberation_meta_of_json (json : Yojson.Safe.t) : deliberation_meta =
  {
    deliberation_count =
      Safe_ops.json_int ~default:0 "deliberation_count" json;
    deliberation_cost_total_usd =
      Safe_ops.json_float ~default:0.0 "deliberation_cost_total_usd" json;
    last_deliberation_ts =
      Safe_ops.json_float ~default:0.0 "last_deliberation_ts" json;
    last_triage_triggers =
      Safe_ops.json_string ~default:"" "last_triage_triggers" json;
  }

(* ---------- Structured result / action source / legality / execution result ---------- *)

type structured_result = {
  action: deliberation_action;
  reasoning: string;
  confidence: float;
}

type action_source =
  | Baseline
  | Structured_model
  | Fallback_after_validation_failure

let action_source_to_string = function
  | Baseline -> "baseline"
  | Structured_model -> "structured_model"
  | Fallback_after_validation_failure -> "fallback_after_validation_failure"

let action_source_to_json source =
  `String (action_source_to_string source)

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

let rec policy_labels_of_action = function
  | MultiStep actions ->
      List.concat_map policy_labels_of_action actions
  | action ->
      [ deliberation_action_to_policy_label action ]

(* ---------- Observation predicates ---------- *)

let has_board_signal (obs : world_observation) =
  obs.board_new_post_count > 0 || obs.board_mention_count > 0

let has_room_signal (obs : world_observation) =
  obs.direct_mention || obs.has_question

let has_operational_signal (obs : world_observation) =
  has_room_signal obs
  || obs.failed_task_count > 0
  || obs.unclaimed_task_count > 0
  || obs.agent_count_changed
  || has_board_signal obs

(** Self-directed context: keeper is idle with no goals.
    Deterministic predicate — same conditions as the L3 SelfDirectedExplore
    trigger in [triage]. Used in [legality_error] to relax action gates
    for keepers exploring autonomously.
    Ref: CSA autonomy Level 2-3 — human monitors, agent acts. *)
let is_self_directed (obs : world_observation) =
  obs.active_goal_count = 0 && obs.idle_seconds > obs.idle_gate * 4
